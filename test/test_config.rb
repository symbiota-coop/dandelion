$VERBOSE = false
require File.expand_path('../config/boot', __dir__)

require 'capybara'
require 'capybara/dsl'
require 'capybara/cuprite'
require 'factory_bot'
require 'minitest/autorun'
require 'minitest/rg'
require 'rack_session_access/capybara'

Capybara.app = Padrino.application
Capybara.server_port = ENV['PORT']
Capybara.save_path = 'capybara'
Capybara.default_max_wait_time = 10
FileUtils.rm_rf("#{Capybara.save_path}/.") unless ENV['CI']

Capybara.register_driver :cuprite do |app|
  options = {}
  options[:js_errors] = false
  Capybara::Cuprite::Driver.new(app, options)
end
Capybara.javascript_driver = :cuprite
Capybara.default_driver = :cuprite

module ActiveSupport
  class TestCase
    def login_as(account)
      page.set_rack_session(account_id: account.id.to_s)
      visit '/'
    end
  end
end
