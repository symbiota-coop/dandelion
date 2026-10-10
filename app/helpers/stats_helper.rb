RUNNING_COMMIT_TIMES = {} # rubocop:disable Style/MutableConstant

Dandelion::App.helpers do
  # When the running commit was made: from the local git history if the deploy has it, otherwise from GitHub.
  # Looked up once per process, as the commit can't change without a restart
  def running_commit_time(commit)
    return RUNNING_COMMIT_TIMES[commit] if RUNNING_COMMIT_TIMES.key?(commit)

    RUNNING_COMMIT_TIMES[commit] = begin
      require 'open3'
      output, status = Open3.capture2('git', '-C', Padrino.root, 'show', '-s', '--format=%cI', commit, err: File::NULL)
      if status.success? && !output.strip.empty?
        Time.iso8601(output.strip)
      else
        Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN']).commit('symbiota-coop/dandelion', commit).commit.committer.date
      end
    rescue StandardError
      nil
    end
  end

  # The releases traces were saved by, with when each was committed, newest first. Releases whose commit time can't be
  # found are left out
  def trace_releases
    Trace.distinct(:release).compact.filter_map { |release| (time = running_commit_time(release)) && [release, time] }.sort_by { |_release, time| time }.reverse
  end

  # A compact age like 8m, 2h, 3d or 1y
  def short_time_ago(time)
    seconds = [Time.now - time, 0].max
    if seconds < 1.hour
      "#{(seconds / 1.minute).floor}m"
    elsif seconds < 1.day
      "#{(seconds / 1.hour).floor}h"
    elsif seconds < 365.days
      "#{(seconds / 1.day).floor}d"
    else
      "#{(seconds / 365.days).floor}y"
    end
  end

  # The query string for a transaction: its name, and whether it's XHR when that's known
  def transaction_query(name, xhr)
    query = "name=#{CGI.escape(name)}"
    query += "&xhr=#{xhr ? 1 : 0}" unless xhr.nil?
    query
  end

  # Text (a transaction's name, a span's op or description), escaped, that can break after each slash or dot rather
  # than anywhere (GET /accounts/:id/ show_feedback, template. render), so it wraps cleanly in narrow table columns
  def wrap_at_separators(text)
    ERB::Util.html_escape(text).gsub(%r{[/.]}, '\\0<wbr>').html_safe
  end

  # Which section of /stats/transactions a transaction goes in: XHR, GET or POST, Jobs for background jobs (named by
  # their class and method, not an HTTP method and path), or Other
  def transaction_section(summary)
    method = summary[:name][/\A[A-Z]+(?= |\z)/]
    if summary[:xhr] then 'XHR'
    elsif %w[GET POST].include?(method) then method
    elsif method then 'Other'
    else 'Jobs'
    end
  end

  # A duration in ms in the largest unit that keeps it above 1: 78 ms, 44.1 s, 12.5 min, 3.2 h
  def format_duration(ms)
    if ms < 1000 then "#{ms.round} ms"
    elsif ms < 60_000 then "#{(ms / 1000.0).round(1)} s"
    elsif ms < 3_600_000 then "#{(ms / 60_000.0).round(1)} min"
    else "#{(ms / 3_600_000.0).round(1)} h"
    end
  end

  def sentry_span_entries
    sentry_span_source_files.flat_map do |file_path|
      sentry_spans_in_file(file_path)
    end.sort_by { |span| [span[:op].to_s, span[:file], span[:line]] }
  end

  def sentry_span_source_files
    root_path = Padrino.root.to_s
    ignored_dirs = %w[.git .bundle .claude log tmp vendor node_modules public]

    files = []
    Find.find(root_path) do |file_path|
      if File.directory?(file_path)
        Find.prune if ignored_dirs.include?(File.basename(file_path))
        next
      end

      next unless File.file?(file_path)
      next unless %w[.rb .erb .rake].include?(File.extname(file_path))

      files << file_path
    end
    files
  end

  def sentry_spans_in_file(file_path)
    lines = File.readlines(file_path)
    relative_path = file_path.sub("#{Padrino.root}/", '')

    lines.each_with_index.filter_map do |line, index|
      next unless sentry_span_creation_line?(line)

      snippet = lines[index, 8].join
      {
        file: relative_path,
        line: index + 1,
        op: sentry_span_keyword_value(snippet, 'op'),
        description: sentry_span_keyword_value(snippet, 'description')
      }
    end
  rescue StandardError
    []
  end

  def sentry_span_creation_line?(line)
    line.match?(/(?:\A|[=\s(])Sentry\.(?:with_child_span|start_span|start_transaction)\s*\(/) ||
      line.match?(/(?:\A|[=\s])\w+\.start_child\(/)
  end

  def sentry_span_keyword_value(snippet, keyword)
    match = snippet.match(/#{Regexp.escape(keyword)}:\s*(?<value>(?:"(?:\\"|[^"])*")|(?:'(?:\\'|[^'])*')|[^,\n]+)/)
    return unless match

    value = match[:value].strip
    value = value.sub(/\s*\)\s*do(?:\s*\|.*)?\z/, '')
    if (value.start_with?("'") && value.end_with?("'")) || (value.start_with?('"') && value.end_with?('"'))
      value[1..-2]
    else
      value
    end
  end

  def version_bump_cells(current_version, version_strings)
    return nil if version_strings.nil? || version_strings.empty?

    current = Gem::Version.new(current_version)
    versions = version_strings.filter_map do |version|
      [version, Gem::Version.new(version)]
    rescue ArgumentError
      nil
    end
    return nil if versions.empty?

    major, minor = current.segments[0], current.segments[1] || 0

    major_bump = versions.select { |_, version| version.segments[0] > major }.max_by(&:last)&.first
    latest_same_major = versions.select { |_, version| version.segments[0] == major }.max_by(&:last)
    minor_bump = if latest_same_major && latest_same_major.last > current && (latest_same_major.last.segments[1] || 0) > minor
                   latest_same_major.first
                 end

    latest_same_minor = versions.select do |_, version|
      version.segments[0] == major && (version.segments[1] || 0) == minor
    end.max_by(&:last)
    patch_bump = latest_same_minor.first if latest_same_minor && latest_same_minor.last > current

    check = :check
    return [check, check, check] unless major_bump || minor_bump || patch_bump
    return [major_bump, nil, nil] if major_bump
    return [check, minor_bump, nil] if minor_bump

    [check, check, patch_bump]
  rescue ArgumentError
    nil
  end

  def fetch_frontend_dependency(base_url, path)
    uri = URI.parse(base_url.to_s)
    fetch_npm_dependency(path) if uri.host&.downcase == 'cdn.jsdelivr.net' && uri.path == '/npm/'
  rescue URI::InvalidURIError
    nil
  end

  def fetch_npm_dependency(path)
    # jsDelivr npm format: 'package@version' => 'files' (the package may be scoped: '@scope/package@version')
    name, _, version = path.rpartition('@')

    response = Faraday.get("https://registry.npmjs.org/#{name.gsub('/', '%2F')}")
    return { name: name, version: version, source: 'npm' } unless response.status == 200

    data = JSON.parse(response.body)
    released_at = data.dig('time', version)
    latest_released_at = data.dig('time', data.dig('dist-tags', 'latest'))

    {
      name: name,
      version: version,
      version_bump_cells: version_bump_cells(version, data['versions']&.keys&.reject { |v| v.include?('-') }),
      release_date: released_at && Time.parse(released_at),
      latest_release_date: latest_released_at && Time.parse(latest_released_at),
      source: 'npm',
      homepage: data['homepage'],
      repository: data.dig('repository', 'url')&.sub(/\Agit\+/, '')&.sub(%r{\A(git|ssh)://(git@)?}, 'https://')&.sub(/\.git\z/, ''),
      description: data['description']&.split('.')&.first
    }
  rescue StandardError
    { name: name, version: version, source: 'npm' }
  end

  def fetch_gem_info(gem_name)
    response = Faraday.get("https://rubygems.org/api/v1/gems/#{gem_name}.json")
    if response.status == 200
      data = JSON.parse(response.body)
      installed_version = get_installed_gem_version(gem_name)
      version = installed_version || data['version']
      {
        name: data['name'],
        version: version,
        version_bump_cells: version_bump_cells(version, fetch_rubygems_versions(gem_name)),
        updated_at: Time.parse(data['version_created_at']),
        downloads: data['downloads'],
        homepage: data['homepage_uri'],
        source_code: data['source_code_uri'],
        info: data['info']&.to_s&.split('.')&.first
      }
    else
      { name: gem_name, version: nil, version_bump_cells: nil, updated_at: nil, downloads: nil, homepage: nil, source_code: nil, info: nil }
    end
  rescue StandardError
    { name: gem_name, version: nil, version_bump_cells: nil, updated_at: nil, downloads: nil, homepage: nil, source_code: nil, info: nil }
  end

  def fetch_rubygems_versions(gem_name)
    response = Faraday.get("https://rubygems.org/api/v1/versions/#{gem_name}.json")
    return nil unless response.status == 200

    JSON.parse(response.body).reject { |entry| entry['prerelease'] }.map { |entry| entry['number'] }
  rescue StandardError
    nil
  end

  def get_installed_gem_version(gem_name)
    gemfile_lock_path = Padrino.root('Gemfile.lock')
    return nil unless File.exist?(gemfile_lock_path)

    content = File.read(gemfile_lock_path)
    # Look for all gem entries in Gemfile.lock format: "gem_name (version)"
    # Actual installed gems are at 4 spaces indentation and have simple version numbers
    # Dependency requirements are at 6+ spaces and have constraints like ">= 5.0"
    matches = content.scan(/^(\s+)#{Regexp.escape(gem_name)}\s+\(([^)]+)\)/)

    # Find the actual gem entry (4 spaces) with a simple version number (not a constraint)
    matches.each do |indent, version|
      # Actual gem entries are at 4 spaces, and version should look like a version number
      # (not contain operators like >=, ~>, <, etc.)
      return version if indent.length == 4 && !version.match?(/[<>=~]/)
    end

    # Fallback: return the last match (actual gems come after dependencies)
    matches.last&.last
  end

  # Colours for a doughnut's segments: the hue of --theme-500 turned evenly round the wheel at a fixed, soft
  # oklch lightness and chroma (near the old #57B98C), so every segment has the same weight. They're CSS, so
  # resolve them in the browser with cssColor
  def chart_colors(count)
    count.times.map do |i|
      degrees = (i.to_f / (count - 1)) * (360 - (360 / count))
      degrees.finite? ? "oklch(from var(--theme-500) 0.71 0.11 calc(h + #{degrees.round(2)}))" : 'var(--bs-gray-200)'
    end
  end
end
