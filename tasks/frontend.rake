namespace :frontend do
  desc 'Hash each CDN file that has no hash yet into frontend/integrity.json, for the integrity attributes cdn_tag writes, and drop those nothing loads'
  task :integrity do
    require 'faraday'
    require 'digest'
    root = File.expand_path('..', __dir__)
    load File.join(root, 'config/frontend_dependencies.rb') unless defined?(FRONTEND_CDN_URLS)
    path = File.join(root, 'frontend/integrity.json')
    # Read from the file rather than FRONTEND_INTEGRITY, which the app loaded at boot
    existing = File.exist?(path) ? JSON.parse(File.read(path)) : {}

    # A file that already has a hash keeps it, so a file that's changed on the CDN since is refused rather than trusted
    hashes = FRONTEND_CDN_URLS.call(root).uniq.sort.to_h do |url|
      next [url, existing[url]] if existing[url]

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
