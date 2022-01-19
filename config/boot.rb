# Defines our constants
RACK_ENV = ENV['RACK_ENV'] ||= 'development' unless defined?(RACK_ENV)
PADRINO_ROOT = File.expand_path('..', __dir__) unless defined?(PADRINO_ROOT)

# Load our dependencies
require 'rubygems' unless defined?(Gem)
require 'bundler/setup'
require 'open-uri'
require 'active_support/time'
Bundler.require(:default, RACK_ENV)

#  Dir['app/views/**/*.erb'].each { |p| puts p; `htmlbeautifier #{p} -b 2` }

Padrino.load!

Mongoid.load!("#{PADRINO_ROOT}/config/mongoid.yml")
Mongoid.raise_not_found_error = false

Delayed::Worker.max_attempts = 1

Geocoder.configure(lookup: :google, api_key: ENV['GOOGLE_MAPS_API_KEY'])

eu_bank = EuCentralBank.new
Money.default_bank = eu_bank
eu_bank.update_rates

Time.zone = 'London'

PUSHER = Pusher::Client.new(app_id: ENV['PUSHER_APP_ID'], key: ENV['PUSHER_KEY'], secret: ENV['PUSHER_SECRET'], cluster: ENV['PUSHER_CLUSTER'], encrypted: true) if ENV['PUSHER_APP_ID']

if ENV['GOOGLE_MAPS_API_KEY']
  Timezone::Lookup.config(:google) do |c|
    c.api_key = ENV['GOOGLE_MAPS_API_KEY']
  end
end

Money.locale_backend = :currency
Money.rounding_mode = BigDecimal::ROUND_HALF_EVEN

OmniAuth.config.allowed_request_methods = [:get]
OmniAuth.config.logger = Logger.new(IO::NULL)
