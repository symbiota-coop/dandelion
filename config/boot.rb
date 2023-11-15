# Defines our constants
RACK_ENV = ENV['RACK_ENV'] ||= 'development' unless defined?(RACK_ENV)
PADRINO_ROOT = File.expand_path('..', __dir__) unless defined?(PADRINO_ROOT)

# Load our dependencies
require 'rubygems' unless defined?(Gem)
require 'bundler/setup'
require 'open-uri'
require 'active_support/time'
require 'money/bank/uphold'
require 'will_paginate/array'
Bundler.require(:default, RACK_ENV)

Padrino.load!

Mongoid.load!("#{PADRINO_ROOT}/config/mongoid.yml")
Mongoid.raise_not_found_error = false

OmniAuth.config.allowed_request_methods = [:get]
OmniAuth.config.logger = Logger.new(IO::NULL)

Delayed::Worker.max_attempts = 1

Money.default_bank = Money::Bank::Uphold.new
Money.locale_backend = :currency
Money.rounding_mode = BigDecimal::ROUND_HALF_EVEN

Time.zone = ENV['DEFAULT_TIME_ZONE']

Airrecord.api_key = ENV['AIRTABLE_API_KEY']

PUSHER = Pusher::Client.new(app_id: ENV['PUSHER_APP_ID'], key: ENV['PUSHER_KEY'], secret: ENV['PUSHER_SECRET'], cluster: ENV['PUSHER_CLUSTER'], encrypted: true) if ENV['PUSHER_APP_ID']

if ENV['GOOGLE_MAPS_API_KEY']
  Geocoder.configure(
    lookup: :google,
    google: {
      api_key: ENV['GOOGLE_MAPS_API_KEY']
    }
  )

  Timezone::Lookup.config(:google) do |c|
    c.api_key = ENV['GOOGLE_MAPS_API_KEY']
  end
end
