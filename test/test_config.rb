$VERBOSE = nil
require_relative 'test_coverage'
require File.expand_path('../config/boot', __dir__)
raise "Refusing to run tests outside test environment. Current Padrino.env=#{Padrino.env.inspect}. Run with `env -u BUNDLE_PATH foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb`" unless Padrino.env == :test

require 'capybara'
require 'capybara/dsl'
require 'capybara/cuprite'
require 'factory_bot'
require 'minitest/autorun'
require 'minitest/mock'
require 'minitest/rg'
require 'rack/test'
require_relative 'helpers/test_helpers'

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

# Tests don't look email domains up in DNS: it's slow, and a domain that stops resolving fails tests that aren't about it
EmailAddress::Config.configure(host_validation: :syntax)

# Configure Geocoder for testing (avoid real API calls)
Geocoder.configure(lookup: :test)
Geocoder::Lookup::Test.set_default_stub([{ 'coordinates' => [59.3251, 18.0685] }]) # Gamla Stan coords (111 28, Sweden)

test_run_running = lambda do |pid|
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

# Drop this run's database (see config/boot.rb) when it ends, and any left by runs that didn't finish
Mongoid.default_client.database_names.grep(/\Adandelion_test_(\d+)\z/) do |name|
  Mongoid.default_client.use(name).database.drop unless test_run_running.call(Regexp.last_match(1).to_i)
end
Minitest.after_run { Mongoid.default_client.database.drop }

# Remove the screenshots of runs that have finished, once they're an hour old
Dir.glob('capybara/*/').each do |dir|
  pid = File.basename(dir)
  FileUtils.rm_rf(dir) if pid.match?(/\A\d+\z/) && !test_run_running.call(pid.to_i) && File.mtime(dir) < 1.hour.ago
rescue Errno::ENOENT
  # Another run starting at the same time removed it first
end

module ActiveSupport
  class TestCase
    include TestHelpers

    # In CI a failing test runs again, up to TEST_ATTEMPTS times in all, before it counts as failed: browser tests can
    # fail on timing alone. Each attempt is a fresh instance, and setup's reset! empties the database first. A test that
    # passes on a later attempt gets a warning on the run's summary, so flaky tests stay visible. Locally a test runs
    # once, so a real failure shows at once rather than after three runs
    TEST_ATTEMPTS = ENV['CI'] ? 3 : 1

    # Minitest's own hook for how one test runs (Minitest::Runnable.run)
    def self.run(klass, method_name, reporter)
      reporter.prerecord klass, method_name
      result = nil
      (1..TEST_ATTEMPTS).each do |attempt|
        result = klass.new(method_name).run
        if result.passed? || result.skipped?
          puts "::warning title=Flaky test::#{klass}##{method_name} passed on attempt #{attempt} of #{TEST_ATTEMPTS}" if attempt > 1
          break
        end
        puts "\n🔁 #{klass}##{method_name} failed on attempt #{attempt} of #{TEST_ATTEMPTS}: #{result.failure.message.lines.first}" if attempt < TEST_ATTEMPTS
      end
      reporter.record result
    end

    setup do
      puts "\n🧪 Running: #{name}"
      reset!
      if ENV['CREATE_VIDEO']
        FileUtils.rm_f(Dir.glob("#{Capybara.save_path}/*.{png,mp4}"))
        @video_steps = []
        @client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
      end
    end

    teardown do
      # Only once the test has used the page (Capybara's own flag, with no reader): a screenshot starts Chrome, which
      # model and Rack tests otherwise never need, and which can't start in some agents' sandboxes (Codex's on macOS)
      save_screenshot if !ENV['CI'] && respond_to?(:save_screenshot) && page.instance_variable_get(:@touched)
    end

    # The doc claims this test checks, as 'page/id@hash' (lib/doc_claims.rb): test/lint_test.rb reads them, so they do
    # nothing here
    def covers(*claims); end

    def reset!
      Capybara.reset_sessions!
      AppModels.all.each do |model|
        next unless model.respond_to?(:delete_all)

        # Paranoia models scope delete_all to non-deleted rows; purge soft-deleted rows too
        (model.respond_to?(:unscoped) ? model.unscoped : model).delete_all
      end
    end

    # Rack::Test's app
    def app
      Padrino.application
    end
  end
end
