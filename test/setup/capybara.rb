# Capybara and the Cuprite (headless Chrome) driver browser tests use
Capybara.app = Padrino.application
Capybara.server_port = ENV['PORT']
# Each run saves its screenshots to its own folder, so runs at the same time don't delete each other's
Capybara.save_path = ENV['CREATE_VIDEO'] ? 'capybara' : "capybara/#{Process.pid}"
Capybara.default_max_wait_time = 10

Capybara.register_driver :cuprite do |app|
  options = {}
  options[:js_errors] = true # a JavaScript error on the page fails the test
  # Tests have no Maps key, so the Maps API is blocked: otherwise Google's own scripts, which change weekly, can throw
  # on the page and fail tests that aren't about maps. Maps show their could-not-load message, and tests of places.js
  # fake the Places library (FAKE_PLACES_JS in accounts/accounts_test.rb)
  options[:url_blacklist] = [%r{\Ahttps://maps\.googleapis\.com/}]
  options[:timeout] = 60
  options[:process_timeout] = 30
  options[:window_size] = ENV['CREATE_VIDEO'] ? [1920, 1080] : [1280, 720]
  options[:headless] = true
  options[:browser_options] = {}
  # Reduced motion turns off the view transitions between pages (app.css), which Chrome aborts with a page error when a
  # click navigates again before the last one has finished, and the app's other transitions, so nothing waits on them
  options[:browser_options]['force-prefers-reduced-motion'] = nil
  options[:browser_options]['no-sandbox'] = nil if Process.uid.zero? # Chromium won't start as root (e.g. cloud agent containers) otherwise
  options[:browser_options]['proxy-server'] = ENV['HTTPS_PROXY'] if ENV['HTTPS_PROXY'] # Chromium ignores HTTPS_PROXY, so CDN requests fail behind an agent proxy
  Capybara::Cuprite::Driver.new(app, options)
end
Capybara.javascript_driver = :cuprite
Capybara.default_driver = :cuprite
