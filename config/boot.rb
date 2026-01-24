# Defines our constants
RACK_ENV = ENV['RACK_ENV'] ||= 'development' unless defined?(RACK_ENV)
PADRINO_ROOT = File.expand_path('..', __dir__) unless defined?(PADRINO_ROOT)
EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
MAP_POINTS_LIMIT = 1000

# Load our dependencies
require 'rubygems' unless defined?(Gem)
require 'bundler/setup'
require 'open-uri'
require 'active_support/time'
require 'will_paginate/array'
Bundler.require(:default, RACK_ENV)

Mongoid.load!("#{PADRINO_ROOT}/config/mongoid.yml")
Mongoid.raise_not_found_error = false

Padrino.load!

OmniAuth.config.allowed_request_methods = [:get]
OmniAuth.config.logger = Logger.new(IO::NULL)

Delayed::Worker.max_attempts = 1

require 'money/bank/uphold'
Money.default_bank = Money::Bank::Uphold.new
# require 'eu_central_bank'
# eu_bank = EuCentralBank.new
# Money.default_bank = eu_bank
# eu_bank.update_rates

Money.locale_backend = :currency
Money.rounding_mode = BigDecimal::ROUND_HALF_EVEN

if Padrino.env == :production
  begin
    MaxMinder.download
  rescue StandardError => e
    Honeybadger.notify(e)
  end
end

Time.zone = ENV['DEFAULT_TIME_ZONE']

Airrecord.api_key = ENV['AIRTABLE_API_KEY']

Yt.configure do |config|
  config.api_key = ENV['YOUTUBE_API_KEY']
end

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

OpenAI.configure do |config|
  config.access_token = ENV['OPENAI_API_KEY']
end
