# Defines our constants
RACK_ENV = ENV['RACK_ENV'] ||= 'development' unless defined?(RACK_ENV)
PADRINO_ROOT = File.expand_path('..', __dir__) unless defined?(PADRINO_ROOT)
EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
MAP_POINTS_LIMIT = 1000
ADJECTIVES = %w[soulful regenerative metamodern participatory conscious transformative holistic ethical].freeze

# Load our dependencies
require 'rubygems' unless defined?(Gem)
require 'bundler/setup'
require 'open-uri'
require 'active_support/time'
require 'active_support/security_utils'
require 'will_paginate/array'
Bundler.require(:default, RACK_ENV)

require File.expand_path('../lib/error_tracking', __dir__)
ErrorTracking.bootstrap!(root: PADRINO_ROOT)

Mongoid.load!("#{PADRINO_ROOT}/config/mongoid.yml")
Mongoid.raise_not_found_error = false
Mongoid.autosave_saves_unchanged_documents = false

Padrino.load!

OmniAuth.config.allowed_request_methods = [:get]
OmniAuth.config.logger = Logger.new(IO::NULL)

Delayed::Worker.max_attempts = 1
Delayed::Worker.max_run_time = 15.minutes
Delayed::Worker.destroy_failed_jobs = false

Money.default_currency = ENV['DEFAULT_CURRENCY']
Money.default_bank = DandelionBank.new
Money.locale_backend = :currency
Money.rounding_mode = BigDecimal::ROUND_HALF_UP

if Padrino.env == :production
  begin
    MaxMinder.download
  rescue StandardError => e
    ErrorTracking.notify(e)
  end
end

Time.zone = ENV['DEFAULT_TIME_ZONE']

Airrecord.api_key = ENV['AIRTABLE_API_KEY']

Yt.configure do |config|
  config.api_key = ENV['YOUTUBE_API_KEY']
end

Geocoder.configure(
  lookup: :google,
  google: {
    api_key: ENV['GOOGLE_MAPS_API_KEY'] || 'missing_api_key'
  }
)

Timezone::Lookup.config(:google) do |c|
  c.api_key = ENV['GOOGLE_MAPS_API_KEY'] || 'missing_api_key'
end

OpenAI.configure do |config|
  config.access_token = ENV['OPENAI_API_KEY']
end
