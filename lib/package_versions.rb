require 'json'
require 'time'

# Which versions of a gem or npm package we can move to, under AGENTS.md's Dependencies: never a version released less
# than COOLDOWN_DAYS ago. /stats/packages shows them, rake dependencies:bump_npm moves to them, rake frontend:integrity
# refuses newer ones, and the npm installs in rake tasks keep to them. The Gemfile's cooldown is the same number
# (test_gemfile_cooldown_matches)
module PackageVersions
  COOLDOWN_DAYS = 7

  # Our npm manifests and the key their packages are under: the linters (installed from package-lock.json) and the
  # packages the app loads from jsDelivr (frontend/package.json)
  NPM_MANIFESTS = { 'package.json' => 'devDependencies', 'frontend/package.json' => 'dependencies' }.freeze

  # When the cooldown starts: a version released after this is too new
  def self.cooldown_start(now = Time.now)
    now - (COOLDOWN_DAYS * 86_400)
  end

  # The date for npm install --before, so the packages it installs and their dependencies keep to the cooldown
  def self.npm_before
    cooldown_start.strftime('%F')
  end

  # Of a package's releases ({ version => release time }), those out of the cooldown: the ones we can upgrade to
  def self.outside_cooldown(releases, now: Time.now)
    releases.select { |_, released_at| released_at && released_at <= cooldown_start(now) }
  end

  # An npm package's registry document, with its versions and when each was released
  def self.npm_document(package)
    require 'faraday'
    response = Faraday.get("https://registry.npmjs.org/#{package.gsub('/', '%2F')}")
    raise "#{package}: npm registry #{response.status}" unless response.status == 200

    JSON.parse(response.body)
  end

  # Whether jsDelivr minified a CDN file itself (a .min file the package doesn't have), as its output can change, so
  # we load the package's own file instead
  def self.jsdelivr_minified?(body)
    body[0, 500].include?('Minified by jsDelivr')
  end

  # An npm package's stable releases ({ version => release time }), from its npm registry document
  def self.npm_releases(registry_document)
    (registry_document['versions'] || {}).keys.reject { |version| version.include?('-') }.to_h do |version|
      [version, registry_document.dig('time', version)&.then { |time| Time.parse(time) }]
    end
  end

  # The newest of a package's releases with the same major version as the current one and out of the cooldown, or the
  # current version if none is newer. A new major version is for a person to choose (/stats/packages lists them)
  def self.newest_in_major(current, releases, now: Time.now)
    current_version = Gem::Version.new(current)
    candidates = outside_cooldown(releases, now: now).keys.filter_map do |version|
      parsed = Gem::Version.new(version)
      [version, parsed] if !parsed.prerelease? && parsed.segments.first == current_version.segments.first && parsed > current_version
    rescue ArgumentError
      nil
    end
    candidates.max_by(&:last)&.first || current
  end
end
