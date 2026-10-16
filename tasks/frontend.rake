namespace :frontend do
  desc 'Hash each CDN file that has no hash yet into config/frontend_integrity.rb, for the integrity attributes cdn_tag writes, and drop those nothing loads'
  task :integrity do
    require 'faraday'
    require 'digest'
    root = File.expand_path('..', __dir__)
    load File.join(root, 'config/frontend_dependencies.rb') unless defined?(FRONTEND_CDN_URLS)
    path = File.join(root, 'config/frontend_integrity.rb')
    load path unless defined?(FRONTEND_INTEGRITY)

    # A file that already has a hash keeps it, so a file that's changed on the CDN since is refused rather than trusted
    hashes = FRONTEND_CDN_URLS.call(root).uniq.sort.to_h do |url|
      next [url, FRONTEND_INTEGRITY[url]] if FRONTEND_INTEGRITY[url]

      response = Faraday.get(url)
      raise "#{url}: #{response.status}" unless response.status == 200
      # jsDelivr minifies a .min file a package doesn't have itself, and its output can change: load the package's own file
      raise "#{url}: minified by jsDelivr, not in the package" if response.body[0, 500].include?('Minified by jsDelivr')

      puts url
      [url, "sha384-#{Digest::SHA384.base64digest(response.body)}"]
    end

    File.write(path, <<~RUBY)
      # The hash of each CDN file the app loads, which cdn_tag writes as its integrity attribute. Written by
      # rake frontend:integrity: run it after adding or removing a CDN file
      FRONTEND_INTEGRITY = {
      #{hashes.map { |url, hash| "  '#{url}' => '#{hash}'" }.join(",\n")}
      }.freeze
    RUBY
  end
end
