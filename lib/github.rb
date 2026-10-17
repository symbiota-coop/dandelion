# Reads Dandelion's repository through the GitHub REST API, as GITHUB_ACCESS_TOKEN when it's set
module Github
  REPO = 'symbiota-coop/dandelion'.freeze

  # The parsed JSON of a GET, e.g. Github.get("repos/#{Github::REPO}/commits", per_page: 20). Raises unless it succeeds
  def self.get(path, params = {})
    headers = { 'Accept' => 'application/vnd.github+json' }
    headers['Authorization'] = "Bearer #{ENV['GITHUB_ACCESS_TOKEN']}" if ENV['GITHUB_ACCESS_TOKEN']
    response = Faraday.get("https://api.github.com/#{path}", params, headers)
    raise "GitHub API #{response.status} for #{path}" unless response.success?

    JSON.parse(response.body)
  end
end
