# How tests run: boot, the setup in test/setup, and each test's hooks. Helpers are in test/helpers
$VERBOSE = nil
require_relative 'setup/coverage'
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

%w[outside_services fake_imagemagick capybara cdn_cache cleanup route_recording].each { |file| require_relative "setup/#{file}" }

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
      RouteRecording.test = "#{self.class.instance_method(name).source_location.join(':')} #{name}" if ENV['RECORD_ROUTES'].present?
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

    # The routes this test is about, as 'VERB /path' as the controller writes it (lib/route_marks.rb): test/lint_test.rb
    # reads them, so they do nothing here
    def covers_route(*routes); end

    def reset!
      Capybara.reset_sessions!
      AppModels.all.each do |model|
        next unless model.respond_to?(:delete_all)

        # Paranoia models scope delete_all to non-deleted rows; purge soft-deleted rows too
        (model.respond_to?(:unscoped) ? model.unscoped : model).delete_all
      end
      Delayed::Job.delete_all # not an app model, so a test's queued jobs would count in the next
    end

    # Rack::Test's app
    def app
      Padrino.application
    end
  end
end
