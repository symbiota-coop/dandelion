# rubocop:disable Lint/Debugger
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
Capybara.save_path = 'capybara'
Capybara.default_max_wait_time = 10
FileUtils.rm_rf("#{Capybara.save_path}/.") unless ENV['CI'] || ENV['CREATE_VIDEO']

Capybara.register_driver :cuprite do |app|
  options = {}
  options[:js_errors] = false
  options[:timeout] = 60
  options[:process_timeout] = 30
  options[:window_size] = [1280, 720]
  options[:headless] = true
  Capybara::Cuprite::Driver.new(app, options)
end
Capybara.javascript_driver = :cuprite
Capybara.default_driver = :cuprite

# Configure Geocoder for testing (avoid real API calls)
Geocoder.configure(lookup: :test)
Geocoder::Lookup::Test.set_default_stub([{ 'coordinates' => [59.3251, 18.0685] }]) # Gamla Stan coords (111 28, Sweden)

module ActiveSupport
  class TestCase
    setup do
      puts "\n🧪 Running: #{name}"
      reset!
      if ENV['CREATE_VIDEO']
        FileUtils.rm_f(Dir.glob("#{Capybara.save_path}/*.{png,mp4}"))
        @step = 1
        @client = OpenAI::Client.new
      end
    end

    teardown do
      save_screenshot if !ENV['CI'] && respond_to?(:save_screenshot)
    end

    def reset!
      Capybara.reset_sessions!
      Dir.glob(Padrino.root('models', '*.rb')).each do |f|
        model = f.split('/').last.split('.').first.camelize.constantize
        model.delete_all if model.respond_to?(:delete_all)
      end
    end

    def sign_in(account)
      account.generate_sign_in_token!
      visit "/?sign_in_token=#{account.sign_in_token}"
    end

    def app
      Padrino.application
    end

    def sign_in_with_rack(account)
      account.generate_sign_in_token!
      get '/', sign_in_token: account.sign_in_token
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
# rubocop:enable Lint/Debugger
