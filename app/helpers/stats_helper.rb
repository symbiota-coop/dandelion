Dandelion::App.helpers do
  def sentry_span_entries
    sentry_span_source_files.flat_map do |file_path|
      sentry_spans_in_file(file_path)
    end.sort_by { |span| [span[:op].to_s, span[:file], span[:line]] }
  end

  def sentry_span_source_files
    root_path = Padrino.root.to_s
    ignored_dirs = %w[.git .bundle log tmp vendor node_modules public]

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
    host = URI.parse(base_url.to_s.sub(/\Agit\+/, ''))&.host&.downcase
    case host
    when 'cdnjs.cloudflare.com'
      fetch_cdnjs_dependency(path)
    when 'rawcdn.githack.com'
      fetch_github_dependency(path)
    end
  rescue URI::InvalidURIError
    nil
  end

  def fetch_cdnjs_dependency(path)
    # cdnjs format: 'library/version' => 'files'
    parts = path.split('/')
    library_name = parts[0]
    version = parts[1]

    response = Faraday.get("https://api.cdnjs.com/libraries/#{library_name}")
    return { name: library_name, version: version, source: 'cdnjs' } unless response.status == 200

    data = JSON.parse(response.body)
    versions = data['versions']
    repo_url = data.dig('repository', 'url')

    # Try to get release date from GitHub
    release_date = fetch_github_release_date(repo_url, version)

    {
      name: library_name,
      version: version,
      version_bump_cells: version_bump_cells(version, versions),
      release_date: release_date,
      source: 'cdnjs',
      homepage: data['homepage'],
      repository: repo_url,
      description: data['description']&.split('.')&.first
    }
  rescue StandardError
    { name: library_name, version: version, source: 'cdnjs' }
  end

  def fetch_github_release_date(repo_url, version)
    github_repo = github_repo_from_url(repo_url)
    return nil unless github_repo

    client = Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN'])

    # Try common tag formats: v1.2.3, 1.2.3
    %W[v#{version} #{version}].each do |tag|
      ref = client.ref(github_repo, "tags/#{tag}")
      # Annotated tags have type 'tag', lightweight tags point directly to 'commit'
      release_date = if ref.object.type == 'tag'
                       client.tag(github_repo, ref.object.sha).tagger&.date
                     else
                       client.commit(github_repo, ref.object.sha).commit.committer.date
                     end
      return release_date if release_date
    rescue Octokit::NotFound
      next
    end
    nil
  rescue StandardError
    nil
  end

  def fetch_github_dependency(path)
    # GitHub format: 'user/repo/commit' => 'files'
    parts = path.split('/')
    user = parts[0]
    repo = parts[1]
    commit = parts[2]

    client = Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN'])
    data = client.commit("#{user}/#{repo}", commit)
    repo_data = client.repository("#{user}/#{repo}")
    commit_date = data.commit.committer.date

    {
      name: "#{user}/#{repo}",
      version: commit[0..6],
      commit_date: commit_date,
      source: 'github',
      homepage: "https://github.com/#{user}/#{repo}",
      description: repo_data.description&.truncate(80)
    }
  rescue StandardError
    { name: "#{user}/#{repo}", version: commit[0..6], source: 'github' }
  end

  def github_repo_from_url(repo_url)
    repo_url = repo_url.to_s.sub(/\Agit\+/, '')
    return nil if repo_url.empty?

    scp_match = repo_url.match(%r{\Agit@github\.com:(?<owner>[^/]+)/(?<repo>[^/?#]+?)(?:\.git)?\z}i)
    return "#{scp_match[:owner]}/#{scp_match[:repo]}" if scp_match

    uri = URI.parse(repo_url)
    return nil unless uri&.host&.downcase == 'github.com'

    owner, repo = uri.path.to_s.split('/').reject(&:empty?)
    return nil if owner.nil? || repo.nil?

    "#{owner}/#{repo.sub(/\.git$/, '')}"
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
end
