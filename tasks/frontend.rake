namespace :frontend do
  desc 'Hash each CDN file that has no hash yet into frontend/integrity.json, for the integrity attributes cdn_tag writes, and drop those nothing loads'
  task :integrity do
    require 'faraday'
    require 'digest'
    require 'time'
    root = File.expand_path('..', __dir__)
    load File.join(root, 'config/frontend_dependencies.rb') unless defined?(FRONTEND_CDN_URLS)
    path = File.join(root, 'frontend/integrity.json')
    # Read from the file rather than FRONTEND_INTEGRITY, which the app loaded at boot
    existing = File.exist?(path) ? JSON.parse(File.read(path)) : {}

    # When each version of a package was published, from the npm registry, fetched once per package
    release_times = Hash.new do |h, package|
      response = Faraday.get("https://registry.npmjs.org/#{package}")
      raise "#{package}: npm registry #{response.status}" unless response.status == 200

      h[package] = JSON.parse(response.body)['time']
    end

    # A file that already has a hash keeps it, so a file that's changed on the CDN since is refused rather than trusted
    hashes = FRONTEND_CDN_URLS.call(root).uniq.sort.to_h do |url|
      next [url, existing[url]] if existing[url]

      # AGENTS.md's cooldown: hashing a version pins whatever it is, so refuse one released less than 7 days ago, giving a
      # compromised release time to be found and pulled first. Only npm packages' files have a release date to check
      if (match = url.match(%r{\Ahttps://cdn\.jsdelivr\.net/npm/((?:@[^/]+/)?[^@/]+)@([^/]+)/}))
        package, version = match.captures
        released = release_times[package][version] or raise "#{package}@#{version}: not on the npm registry"
        age = Time.now - Time.parse(released)
        raise "#{package}@#{version}: released #{format("%.1f", age / 86_400)} days ago, under the 7-day cooldown" if age < 7 * 86_400
      end

      response = Faraday.get(url)
      raise "#{url}: #{response.status}" unless response.status == 200
      # jsDelivr minifies a .min file a package doesn't have itself, and its output can change: load the package's own file
      raise "#{url}: minified by jsDelivr, not in the package" if response.body[0, 500].include?('Minified by jsDelivr')

      puts url
      [url, "sha384-#{Digest::SHA384.base64digest(response.body)}"]
    end

    File.write(path, "#{JSON.pretty_generate(hashes)}\n")
  end
end
