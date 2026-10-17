$VERBOSE = nil
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

Capybara.app = Padrino.application
Capybara.server_port = ENV['PORT']
# Each run saves its screenshots to its own folder, so runs at the same time don't delete each other's
Capybara.save_path = ENV['CREATE_VIDEO'] ? 'capybara' : "capybara/#{Process.pid}"
Capybara.default_max_wait_time = 10

Capybara.register_driver :cuprite do |app|
  options = {}
  options[:js_errors] = false
  options[:timeout] = 60
  options[:process_timeout] = 30
  options[:window_size] = ENV['CREATE_VIDEO'] ? [1920, 1080] : [1280, 720]
  options[:headless] = true
  options[:browser_options] = {}
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
end

module ActiveSupport
  class TestCase
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
      save_screenshot if !ENV['CI'] && respond_to?(:save_screenshot)
    end

    def reset!
      Capybara.reset_sessions!
      AppModels.all.each do |model|
        next unless model.respond_to?(:delete_all)

        # Paranoia models scope delete_all to non-deleted rows; purge soft-deleted rows too
        (model.respond_to?(:unscoped) ? model.unscoped : model).delete_all
      end
    end

    # Factory accounts are unconfirmed, and a code from a new browser would confirm one as someone else (Account#confirm_email!),
    # signing out its other sessions and resetting its password: confirm: false to test that
    def sign_in(account, confirm: true)
      account.set(email_confirmed: true) if confirm
      Capybara.reset_sessions!
      visit "/?sign_in_code=#{account.issue_sign_in_code!}"
    end

    def app
      Padrino.application
    end

    def sign_in_with_rack(account, confirm: true)
      account.set(email_confirmed: true) if confirm
      clear_cookies
      get '/', sign_in_code: account.issue_sign_in_code!
      follow_redirect! while last_response.redirect?
    end

    # Helpers set @account/@organisation/@event/@gathering. Inline FactoryBot/Event.new uses locals.
    def create_organisation(*traits, **attrs)
      @account ||= FactoryBot.create(:account)
      @organisation = FactoryBot.create(:organisation, *traits, account: @account, **attrs)
    end

    def create_event(*traits, as: :event, **attrs)
      create_organisation unless @organisation
      instance_variable_set(:"@#{as}", FactoryBot.create(:event, *traits, organisation: @organisation, **attrs))
    end

    def create_gathering(*traits, **attrs)
      @account ||= FactoryBot.create(:account)
      @gathering = FactoryBot.create(:gathering, *traits, account: @account, **attrs)
    end

    def create_full_event_hierarchy(options = {})
      create_organisation(**options.fetch(:organisation_options, {}))
      @activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'open')
      @local_group = FactoryBot.create(:local_group, organisation: @organisation)

      event_attrs = options.fetch(:event_options, {}).dup
      event_attrs[:activity] = @activity unless options[:skip_activity]
      event_attrs[:local_group] = @local_group unless options[:skip_local_group]
      create_event(**event_attrs)
    end

    def assert_associated(entity, account, association_name)
      assert entity.send(association_name).find_by(account: account),
             "Expected #{account.email} to be associated with #{entity.class.name} '#{entity.try(:name) || entity.id}'"
    end

    def assert_cannot_reassign_organisation_or_account(record)
      other_account = FactoryBot.create(:account)
      other_organisation = FactoryBot.create(:organisation, account: other_account)
      record.organisation = other_organisation
      record.account = other_account
      refute record.valid?
      assert_includes record.errors[:organisation], 'cannot be changed'
      assert_includes record.errors[:account], 'cannot be changed'
    end
  end
end
