require_relative '../lib/package_versions'

namespace :dependencies do
  desc "Bump each npm package in package.json and frontend/package.json to its newest release in its major version that's out of the 7-day cooldown, then refresh package-lock.json and frontend/integrity.json"
  task :bump_npm do
    $stdout.sync = true # so what's bumped comes before npm's output
    require 'faraday'
    root = File.expand_path('..', __dir__)
    load File.join(root, 'config/frontend_dependencies.rb') unless defined?(FRONTEND_CDN_URLS)
    cdn_urls = FRONTEND_CDN_URLS.call(root).uniq

    PackageVersions::NPM_MANIFESTS.each do |manifest, key|
      path = File.join(root, manifest)
      json = JSON.parse(File.read(path))
      json[key] = json[key].to_h do |package, version|
        response = Faraday.get("https://registry.npmjs.org/#{package.gsub('/', '%2F')}")
        raise "#{package}: npm registry #{response.status}" unless response.status == 200

        newest = PackageVersions.newest_in_major(version, PackageVersions.npm_releases(JSON.parse(response.body)))
        next [package, version] if newest == version

        # A CDN package keeps its version if a file the app loads isn't in the new one, or would be minified by jsDelivr
        # (which rake frontend:integrity refuses), so one package can't hold back the rest
        if key == 'dependencies'
          files = cdn_urls.select { |url| url.start_with?("https://cdn.jsdelivr.net/npm/#{package}@#{version}/") }
          missing = files.map { |url| url.sub("@#{version}/", "@#{newest}/") }.find do |url|
            file = Faraday.get(url)
            file.status != 200 || file.body[0, 500].include?('Minified by jsDelivr')
          end
          if missing
            warn "#{package}: keeping #{version}, as #{missing} isn't in #{newest}"
            next [package, version]
          end
        end

        puts "#{package}: #{version} → #{newest}"
        [package, newest]
      end
      File.write(path, "#{JSON.pretty_generate(json)}\n")
    end

    Dir.chdir(root) do
      # The linters' own dependencies a week old too (AGENTS.md's Dependencies)
      sh "npm install --before=#{(Time.now - (PackageVersions::COOLDOWN_DAYS * 86_400)).strftime('%F')}"
      # In a process of its own, as FRONTEND_VERSIONS here still has the versions from before
      sh 'rake frontend:integrity'
    end
  end

  desc 'The gems and npm packages whose versions differ from the last commit, as Markdown (the daily bump pull request)'
  task :changes do
    require 'bundler'
    root = File.expand_path('..', __dir__)
    committed = ->(path) { IO.popen(['git', '-C', root, 'show', "HEAD:#{path}"], &:read) }
    lockfile_versions = ->(source) { Bundler::LockfileParser.new(source).specs.to_h { |spec| [spec.name, spec.version.to_s] } }

    before = lockfile_versions.call(committed.call('Gemfile.lock'))
    lockfile = Bundler::LockfileParser.new(File.read(File.join(root, 'Gemfile.lock')))
    after = lockfile_versions.call(File.read(File.join(root, 'Gemfile.lock')))
    direct = lockfile.dependencies.keys
    gems = after.select { |name, version| before[name] && before[name] != version }.sort_by { |name, _| [direct.include?(name) ? 0 : 1, name] }
    added = after.keys - before.keys
    removed = before.keys - after.keys

    lines = []
    if gems.any? || added.any? || removed.any?
      lines << '### Gems' << '' << '| Gem | From | To |' << '| --- | --- | --- |'
      gems.each do |name, version|
        label = direct.include?(name) ? "**#{name}**" : name
        lines << "| [#{label}](https://rubygems.org/gems/#{name}/versions/#{version}) | #{before[name]} | #{version} |"
      end
      added.sort.each { |name| lines << "| [#{name}](https://rubygems.org/gems/#{name}) (new) | | #{after[name]} |" }
      removed.sort.each { |name| lines << "| #{name} (removed) | #{before[name]} | |" }
      lines << '' << 'Gems in the Gemfile are in bold; the others are their dependencies.' << ''
    end

    PackageVersions::NPM_MANIFESTS.each do |manifest, key|
      old = JSON.parse(committed.call(manifest))[key]
      bumps = JSON.parse(File.read(File.join(root, manifest)))[key].select { |package, version| old[package] && old[package] != version }
      next if bumps.empty?

      lines << "### #{manifest == 'package.json' ? 'Linters' : 'CDN packages'} (`#{manifest}`)" << '' << '| Package | From | To |' << '| --- | --- | --- |'
      bumps.each { |package, version| lines << "| [#{package}](https://www.npmjs.com/package/#{package}/v/#{version}) | #{old[package]} | #{version} |" }
      lines << ''
    end

    puts lines.any? ? lines : 'No changes.'
  end
end
