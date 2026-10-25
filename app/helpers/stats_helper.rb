Dandelion::App.helpers do
  def commit_url(commit)
    "https://github.com/symbiota-coop/dandelion/commit/#{commit}"
  end

  # A commit's short hash, linking to it on GitHub
  def commit_link(commit)
    %(<a target="_blank" href="#{ERB::Util.html_escape(commit_url(commit))}"><code>#{ERB::Util.html_escape(commit[0..6])}</code></a>).html_safe
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

  # Which section of /stats/transactions a transaction goes in: Search for the search page and its XHR requests
  # (above the searches they make), XHR, GET or POST, Jobs for background jobs (named by their class and method, not an
  # HTTP method and path), or Other HTTP (HEAD, PUT, DELETE and the like)
  def transaction_section(summary)
    method = summary[:name][/\A[A-Z]+(?= |\z)/]
    if summary[:name] == 'GET /search' then 'Search'
    elsif summary[:xhr] then 'XHR'
    elsif %w[GET POST].include?(method) then method
    elsif method then 'Other HTTP'
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
    # Dir.glob skips hidden directories (like .git)
    ignored_dirs = %w[log tmp vendor node_modules public]

    Dir.glob('**/*.{rb,erb,rake}', base: root_path).filter_map do |path|
      next if path.split('/').intersect?(ignored_dirs)

      file_path = File.join(root_path, path)
      file_path if File.file?(file_path)
    end
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

  # Of a package's releases ({ version => release time }), those out of the 7-day cooldown on new versions (AGENTS.md's
  # Dependencies): the ones we can upgrade to, so the tables offer only these
  def releases_outside_cooldown(releases)
    PackageVersions.outside_cooldown(releases)
  end

  # The highest version of a package's releases, and its release time
  def latest_release(releases)
    releases.filter_map do |version, released_at|
      [Gem::Version.new(version), released_at]
    rescue ArgumentError
      nil
    end.max_by(&:first)&.last
  end

  # Runs the block on each item in its own thread, returning the non-nil results newest latest release first (unknown
  # dates at the bottom), as the tables sort them
  def fetch_packages(items, &)
    items.map { |item| Thread.new(item, &) }.filter_map(&:value).sort_by { |package| -package[:latest_release_date].to_i }
  end

  # The Ruby and the gems the Gemfile names (but not GitHub gems, which aren't on RubyGems)
  def fetch_gems
    gemfile_content = File.read(Padrino.root('Gemfile'), encoding: 'UTF-8')
    gem_names = gemfile_content.each_line.filter_map do |line|
      next if line.strip.start_with?('#') || line.include?('github:')

      line[/gem ['"]([^'"]+)['"]/, 1]
    end.uniq

    fetch_packages([:ruby] + gem_names) do |gem_name|
      gem_name == :ruby ? fetch_ruby_info(gemfile_content[/^ruby ['"]([^'"]+)['"]/, 1]) : fetch_gem_info(gem_name)
    end
  end

  # Each npm package the app loads from the CDN (FRONTEND_CDN_URLS), with its files' URLs for the size column, and where
  # it's loaded: on every page (FRONTEND_DEPENDENCIES and the layout's own, jQuery) or by the templates that name its files
  def fetch_frontend_dependencies
    shared = FRONTEND_DEPENDENCIES.flat_map { |package, files| files.split.map { |f| FRONTEND_NPM_URL.call(package, f) } }
    views = "#{Padrino.root('app/views')}/"
    templates = Dir["#{views}**/*.erb"].to_h { |f| [f.delete_prefix(views).delete_suffix('.erb'), FRONTEND_TEMPLATE_CDN_URLS.call(File.read(f, encoding: 'UTF-8'))] }
    packages = FRONTEND_CDN_URLS.call(Padrino.root).uniq.group_by { |url| url[%r{/npm/((?:@[^/]+/)?[^/]+)/}, 1] }.except(nil)

    fetch_packages(packages.to_a) do |path, file_urls|
      loaded_on = file_urls.intersect?(shared) ? [] : templates.select { |_, urls| urls.intersect?(file_urls) }.keys
      loaded_on = [] if loaded_on == ['layouts/_dependencies']
      fetch_npm_dependency(path).merge(file_urls: file_urls, loaded_on: loaded_on)
    end
  end

  def fetch_npm_dependency(path)
    # jsDelivr npm format: 'package@version' => 'files' (the package may be scoped: '@scope/package@version')
    name, _, version = path.rpartition('@')

    data = PackageVersions.npm_document(name)
    released_at = data.dig('time', version)
    releases = releases_outside_cooldown(PackageVersions.npm_releases(data))

    {
      name: name,
      version: version,
      version_bump_cells: version_bump_cells(version, releases.keys),
      release_date: released_at && Time.parse(released_at),
      latest_release_date: latest_release(releases),
      downloads: fetch_npm_weekly_downloads(name),
      source: 'npm',
      homepage: data['homepage'],
      source_code: data.dig('repository', 'url')&.sub(/\Agit\+/, '')&.sub(%r{\A(git|ssh)://(git@)?}, 'https://')&.sub(/\.git\z/, ''),
      info: data['description']&.split('.')&.first
    }
  rescue StandardError
    { name: name, version: version, source: 'npm' }
  end

  # npm's downloads over the last week, the figure npmjs.com shows
  def fetch_npm_weekly_downloads(name)
    response = Faraday.get("https://api.npmjs.org/downloads/point/last-week/#{name.gsub('/', '%2F')}")
    JSON.parse(response.body)['downloads'] if response.status == 200
  rescue StandardError
    nil
  end

  def fetch_gem_info(gem_name)
    response = Faraday.get("https://rubygems.org/api/v1/gems/#{gem_name}.json")
    return { name: gem_name } unless response.status == 200

    data = JSON.parse(response.body)
    version = get_installed_gem_version(gem_name) || data['version']
    versions = fetch_rubygems_versions(gem_name) || []
    # The lockfile names a platform gem's platform too (nokogiri 1.18.0-arm64-darwin)
    released = versions.find { |entry| [entry['number'], "#{entry['number']}-#{entry['platform']}"].include?(version) }
    # A version's first platform's release, as each platform's gem is pushed separately
    releases = releases_outside_cooldown(versions.group_by { |entry| entry['number'] }.transform_values { |entries| entries.map { |entry| Time.parse(entry['created_at']) }.min })
    {
      name: data['name'],
      version: version,
      version_bump_cells: version_bump_cells(version, releases.keys),
      release_date: released && Time.parse(released['created_at']),
      latest_release_date: latest_release(releases),
      downloads: data['downloads'],
      homepage: data['homepage_uri'],
      source_code: data['source_code_uri'],
      info: data['info']&.to_s&.split('.')&.first
    }
  rescue StandardError
    { name: gem_name }
  end

  # A gem's stable releases, newest first, each with its number, platform and created_at
  def fetch_rubygems_versions(gem_name)
    response = Faraday.get("https://rubygems.org/api/v1/versions/#{gem_name}.json")
    return nil unless response.status == 200

    JSON.parse(response.body).reject { |entry| entry['prerelease'] }
  rescue StandardError
    nil
  end

  # A row for the gems table: the running Ruby against ruby-lang.org's list of releases, and the Ruby the Gemfile asks for
  def fetch_ruby_info(gemfile_version)
    ruby = { name: 'ruby', url: 'https://www.ruby-lang.org/en/downloads/releases/', version: RUBY_VERSION, gemfile_version: gemfile_version,
             homepage: 'https://www.ruby-lang.org', source_code: 'https://github.com/ruby/ruby', info: 'The Ruby running the app' }
    response = Faraday.get('https://raw.githubusercontent.com/ruby/www.ruby-lang.org/master/_data/releases.yml')
    return ruby unless response.status == 200

    releases = YAML.safe_load(response.body, permitted_classes: [Date]).to_h do |release|
      [release['version'].to_s, release['date']&.then { |date| Time.utc(date.year, date.month, date.day) }]
    end
    stable_releases = releases_outside_cooldown(releases.reject { |version, _| version.include?('-') })
    ruby.merge(version_bump_cells: version_bump_cells(RUBY_VERSION, stable_releases.keys), release_date: releases[RUBY_VERSION], latest_release_date: latest_release(stable_releases))
  rescue StandardError
    ruby
  end

  def get_installed_gem_version(gem_name)
    gemfile_lock_path = Padrino.root('Gemfile.lock')
    return nil unless File.exist?(gemfile_lock_path)

    content = File.read(gemfile_lock_path)
    # Look for all gem entries in Gemfile.lock format: "gem_name (version)"
    # Actual installed gems are at 4 spaces indentation and have simple version numbers
    # Dependency requirements are at 6+ spaces and have constraints like ">= 5.0"
    matches = content.scan(/^(\s+)#{Regexp.escape(gem_name)}\s+\(([^)]+)\)/)

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
