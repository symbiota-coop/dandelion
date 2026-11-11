#!/usr/bin/env ruby
# Updates what /stats/packages lists, to the newest release out of the 7-day cooldown (AGENTS.md's Dependencies), and
# prints a Markdown summary of what it changed, for the pull request the package updates workflow
# (.github/workflows/package-updates.yml) opens:
#
#   ruby script/update_packages.rb > summary.md
#
# Or only some of them, by name (gems, frontend, actions), as the workflow runs gems and frontend in one job and actions
# in another: updating gems runs their code (bundle install, then rake), so it gets no token that can write
#
#   ruby script/update_packages.rb gems frontend > summary.md
#
# - Gems: bundle lock --update, which keeps to the Gemfile's constraints and its source's cooldown, then bundle install
# - Frontend: each package in frontend/package.json, once each file the app loads from it is at the new version on
#   jsDelivr (and is the package's own file, not jsDelivr's minified copy), then rake frontend:integrity hashes them
# - GitHub Actions: each action pinned to a commit (uses: owner/repo@sha # v1.2.3), to the commit of its newest release
#
# Ruby itself isn't updated, as its version is set in several places (the Gemfile, the workflows, Render).
# HOLD keeps a package on a major version. Only the standard library until bundle install, so it runs before it.
# Progress goes to stderr. Reads GITHUB_TOKEN (or GH_TOKEN), if set, for GitHub's rate limit
require 'bundler'
require 'json'
require 'net/http'
require 'open3'
require 'time'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)
load 'config/frontend_dependencies.rb'

COOLDOWN = 7 * 86_400
# Packages kept on a major version, and why
HOLD = {
  'iframe-resizer' => 4 # 5 and later are GPL-3.0, or a paid licence
}.freeze
PACKAGE_JSON = 'frontend/package.json'.freeze
ACTION_FILES = Dir['.github/{workflows/*,actions/*/action}.{yml,yaml}'].freeze
ACTION_PIN = %r{(uses:\s*)([\w.-]+/[\w.-]+)([^@\s]*)@([0-9a-f]{40})(\s*#\s*)(\S+)}

def log(message)
  $stderr.puts message
end

def get(url, headers = {})
  uri = URI(url)
  request = Net::HTTP::Get.new(uri, headers)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) { |http| http.request(request) }
end

def get_json(url, headers = {})
  response = get(url, headers)
  raise "#{url}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
end

def github(path)
  headers = { 'Accept' => 'application/vnd.github+json' }
  token = ENV['GITHUB_TOKEN'] || ENV.fetch('GH_TOKEN', nil)
  headers['Authorization'] = "Bearer #{token}" if token
  get_json("https://api.github.com/#{path}", headers)
end

def version(string)
  Gem::Version.new(string.delete_prefix('v')) if Gem::Version.correct?(string.delete_prefix('v'))
end

# The newest of releases ({ name => release time }) out of the cooldown, newer than current and on a held major
def newest(name, current, releases)
  current_version = version(current) or return
  releases.filter_map do |release, released_at|
    v = version(release)
    next unless v && !v.prerelease? && v > current_version && released_at && Time.now - released_at >= COOLDOWN
    next if HOLD[name] && v.segments.first != HOLD[name]

    [release, v]
  end.max_by(&:last)&.first
end

def major?(from, to)
  version(from).segments.first != version(to).segments.first
end

def lockfile_specs
  Bundler::LockfileParser.new(File.read('Gemfile.lock')).specs.to_h { |spec| [spec.name, spec.version.to_s] }
end

def run(*command)
  output, status = Open3.capture2e(*command)
  $stderr.puts output
  raise "#{command.join(' ')} failed" unless status.success?
end

# [name, from, to] of each gem that changed, by bundle lock --update
def update_gems
  log 'Gems'
  before = lockfile_specs
  run('bundle', 'lock', '--update')
  after = lockfile_specs
  run('bundle', 'install', '--quiet')
  after.filter_map { |name, to| [name, before[name], to] if before[name] != to }.sort
end

# [name, from, to] of each package bumped, and [name, to, reason] of each that couldn't be
def update_frontend
  log 'Frontend'
  json = JSON.parse(File.read(PACKAGE_JSON, encoding: 'UTF-8'))
  urls = FRONTEND_CDN_URLS.call(ROOT).uniq
  updated = []
  skipped = []
  json['dependencies'].each do |name, current|
    registry = get_json("https://registry.npmjs.org/#{name.sub('/', '%2F')}")
    times = registry['time'].to_h { |v, time| [v, Time.parse(time)] }.slice(*registry['versions'].keys)
    to = newest(name, current, times) or next

    log "  #{name} #{current} -> #{to}"
    missing = urls.grep(%r{/npm/#{Regexp.escape(name)}@#{Regexp.escape(current)}/}).filter_map do |url|
      new_url = url.sub("#{name}@#{current}/", "#{name}@#{to}/")
      response = get(new_url)
      file = new_url.split("#{name}@#{to}/").last
      next "#{file} isn't in it" unless response.is_a?(Net::HTTPSuccess)

      "#{file} is minified by jsDelivr, not the package" if response.body[0, 500].include?('Minified by jsDelivr')
    end
    next skipped << [name, to, missing.join(', ')] if missing.any?

    json['dependencies'][name] = to
    updated << [name, current, to]
  end
  File.write(PACKAGE_JSON, "#{JSON.pretty_generate(json)}\n")
  run('bundle', 'exec', 'rake', 'frontend:integrity')
  [updated, skipped]
end

# [action, from, to] of each action bumped
def update_actions
  log 'GitHub Actions'
  pins = ACTION_FILES.flat_map { |file| File.read(file, encoding: 'UTF-8').scan(ACTION_PIN).map { |match| match[1] } }.uniq
  updates = pins.filter_map do |repo|
    releases = github("repos/#{repo}/releases?per_page=100").reject { |release| release['draft'] || release['prerelease'] }
    tags = releases.to_h { |release| [release['tag_name'], Time.parse(release['published_at'])] }
    current = ACTION_FILES.flat_map { |file| File.read(file, encoding: 'UTF-8').scan(ACTION_PIN) }.select { |match| match[1] == repo }.map(&:last)
    oldest = current.min_by { |tag| version(tag) || Gem::Version.new('0') }
    to = newest(repo, oldest, tags) or next

    log "  #{repo} #{oldest} -> #{to}"
    [repo, oldest, to, github("repos/#{repo}/commits/#{to}")['sha']]
  end

  ACTION_FILES.each do |file|
    content = File.read(file, encoding: 'UTF-8')
    updated = updates.reduce(content) do |text, (repo, _, to, sha)|
      text.gsub(ACTION_PIN) do
        match = Regexp.last_match
        match[2] == repo ? "#{match[1]}#{repo}#{match[3]}@#{sha}#{match[5]}#{to}" : match[0]
      end
    end
    File.write(file, updated) if updated != content
  end
  updates.map { |repo, from, to, _| [repo, from, to] }
end

def table(title, rows)
  return if rows.empty?

  puts "### #{title}", '', '| | From | To |', '| --- | --- | --- |'
  rows.each { |name, from, to| puts "| #{name} | #{from} | #{to}#{' **(major)**' if from && to && major?(from, to)} |" }
  puts
end

SECTIONS = %w[gems frontend actions].freeze
sections = ARGV.empty? ? SECTIONS : ARGV
abort "Unknown sections: #{(sections - SECTIONS).join(', ')} (choose from #{SECTIONS.join(', ')})" if (sections - SECTIONS).any?

gems = sections.include?('gems') ? update_gems : []
frontend, skipped = sections.include?('frontend') ? update_frontend : [[], []]
actions = sections.include?('actions') ? update_actions : []

# The introduction, once, from the run that updates gems (the first, in the workflow)
if sections.include?('gems')
  puts 'Updates what /stats/packages lists to the newest release out of the 7-day cooldown, from `script/update_packages.rb`.', ''
  puts 'Major versions can break things: check their changelogs. To keep a package on its major, add it to `HOLD` in the script (or, for a gem, give it a constraint in the Gemfile).', ''
end
table('Gems', gems)
table('Frontend', frontend)
table('GitHub Actions', actions)
if skipped.any?
  puts '### Not updated', ''
  skipped.each { |name, to, reason| puts "- #{name} #{to}: #{reason}" }
  puts
end
