Dandelion::App.helpers do
  def fetch_frontend_dependency(base_url, path)
    if base_url.include?('cdnjs.cloudflare.com')
      fetch_cdnjs_dependency(path)
    elsif base_url.include?('rawcdn.githack.com')
      fetch_github_dependency(path)
    end
  end

  def fetch_cdnjs_dependency(path)
    # cdnjs format: 'library/version' => 'files'
    parts = path.split('/')
    library_name = parts[0]
    version = parts[1]

    response = Faraday.get("https://api.cdnjs.com/libraries/#{library_name}")
    return { name: library_name, version: version, source: 'cdnjs' } unless response.status == 200

    data = JSON.parse(response.body)
    latest_version = data['versions']&.last
    repo_url = data.dig('repository', 'url')

    # Try to get release date from GitHub
    release_date = fetch_github_release_date(repo_url, version)

    {
      name: library_name,
      version: version,
      latest_version: latest_version,
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
    return nil unless repo_url&.include?('github.com')

    # Parse repo from URL formats like:
    # https://github.com/owner/repo, git://github.com/owner/repo.git, git+https://...
    # Repo names can contain dots (e.g. Chart.js), so capture everything then strip .git suffix
    repo_match = repo_url.match(%r{github\.com[/:]([^/]+)/([^/?#]+)})
    return nil unless repo_match

    repo_name = repo_match[2].sub(/\.git$/, '')
    github_repo = "#{repo_match[1]}/#{repo_name}"
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

  def fetch_gem_info(gem_name)
    response = Faraday.get("https://rubygems.org/api/v1/gems/#{gem_name}.json")
    if response.status == 200
      data = JSON.parse(response.body)
      latest_version = data['version']
      # Get installed version from Gemfile.lock if available
      installed_version = get_installed_gem_version(gem_name)
      {
        name: data['name'],
        version: installed_version || latest_version,
        latest_version: latest_version,
        updated_at: Time.parse(data['version_created_at']),
        downloads: data['downloads'],
        homepage: data['homepage_uri'],
        source_code: data['source_code_uri'],
        info: data['info']&.to_s&.split('.')&.first
      }
    else
      { name: gem_name, version: nil, latest_version: nil, updated_at: nil, downloads: nil, homepage: nil, source_code: nil, info: nil }
    end
  rescue StandardError
    { name: gem_name, version: nil, latest_version: nil, updated_at: nil, downloads: nil, homepage: nil, source_code: nil, info: nil }
  end

  def get_installed_gem_version(gem_name)
    gemfile_lock_path = Padrino.root('Gemfile.lock')
    return nil unless File.exist?(gemfile_lock_path)

    content = File.read(gemfile_lock_path)
    # Look for gem entry in Gemfile.lock format: "gem_name (version)"
    match = content.match(/^\s+#{Regexp.escape(gem_name)}\s+\(([^)]+)\)/)
    match ? match[1] : nil
  end
end
