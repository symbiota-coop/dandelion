# Capybara and the Cuprite (headless Chrome) driver browser tests use
Capybara.app = Padrino.application
Capybara.server_port = ENV['PORT']
# Each run saves its screenshots to its own folder, so runs at the same time don't delete each other's
Capybara.save_path = ENV['CREATE_VIDEO'] ? 'capybara' : "capybara/#{Process.pid}"
Capybara.default_max_wait_time = 10

Capybara.register_driver :cuprite do |app|
  options = {}
  options[:js_errors] = true # a JavaScript error on the page fails the test
  # No url_blacklist: Ferrum's would let every request it doesn't block through to the network. CdnCache
  # (test/setup/cdn_cache.rb) blocks the outside scripts tests don't need, and answers the CDN's from a local cache
  options[:timeout] = 60
  options[:process_timeout] = 30
  options[:window_size] = ENV['CREATE_VIDEO'] ? [1920, 1080] : [1280, 720]
  options[:headless] = true
  options[:browser_options] = {}
  # Reduced motion turns off the view transitions between pages (app.css), which Chrome aborts with a page error when a
  # click navigates again before the last one has finished, and the app's other transitions, so nothing waits on them
  options[:browser_options]['force-prefers-reduced-motion'] = nil
  options[:browser_options]['no-sandbox'] = nil if Process.uid.zero? # Chromium won't start as root (e.g. cloud agent containers) otherwise
  options[:browser_options]['proxy-server'] = ENV['HTTPS_PROXY'] if ENV['HTTPS_PROXY'] # Chromium ignores HTTPS_PROXY, so outside requests fail behind an agent proxy
  Capybara::Cuprite::Driver.new(app, options)
end
Capybara.javascript_driver = :cuprite
Capybara.default_driver = :cuprite
