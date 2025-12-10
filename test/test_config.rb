# rubocop:disable Lint/Debugger
$VERBOSE = nil
require File.expand_path('../config/boot', __dir__)

require 'capybara'
require 'capybara/dsl'
require 'capybara/cuprite'
require 'factory_bot'
require 'minitest/autorun'
require 'minitest/rg'

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
      save_screenshot unless ENV['CI']
    end

    def reset!
      Capybara.reset_sessions!
      Dir.glob(Padrino.root('models', '*.rb')).each do |f|
        model = f.split('/').last.split('.').first.camelize.constantize
        model.delete_all if model.respond_to?(:delete_all)
      end
    end

    def login_as(account)
      account.generate_sign_in_token!
      visit "/?sign_in_token=#{account.sign_in_token}"
    end

    def create_full_event_hierarchy(options = {})
      @org_account = FactoryBot.create(:account)
      @organisation = FactoryBot.create(:organisation, account: @org_account, **options.fetch(:organisation_options, {}))
      @activity = FactoryBot.create(:activity, organisation: @organisation, account: @org_account, privacy: 'open')
      @local_group = FactoryBot.create(:local_group, organisation: @organisation, account: @org_account)

      event_attrs = {
        organisation: @organisation,
        account: @org_account,
        last_saved_by: @org_account,
        **options.fetch(:event_options, {})
      }
      event_attrs[:activity] = @activity unless options[:skip_activity]
      event_attrs[:local_group] = @local_group unless options[:skip_local_group]

      @event = FactoryBot.create(:event, **event_attrs)
    end

    def assert_associated(entity, account, association_name)
      assert entity.send(association_name).find_by(account: account),
             "Expected #{account.email} to be associated with #{entity.class.name} '#{entity.try(:name) || entity.id}'"
    end
  end
end
# rubocop:enable Lint/Debugger
