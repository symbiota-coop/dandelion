# Defines our constants
RACK_ENV = ENV['RACK_ENV'] ||= 'development' unless defined?(RACK_ENV)
PADRINO_ROOT = File.expand_path('..', __dir__) unless defined?(PADRINO_ROOT)

# Load our dependencies
require 'rubygems' unless defined?(Gem)
require 'bundler/setup'
require 'open-uri'
require 'active_support/time'
require 'will_paginate/array'
Bundler.require(:default, RACK_ENV)

Padrino.load!

Mongoid.load!("#{PADRINO_ROOT}/config/mongoid.yml")
Mongoid.raise_not_found_error = false

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

FARQUEST = Faraday.new(
  url: 'https://build.far.quest/farcaster/v2',
  headers: { 'Content-Type': 'application/json', 'API-KEY': ENV['FARQUEST_API_KEY'] }
)

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

stylesheets_dir = Padrino.root('app', 'assets', 'stylesheets')
Dir.glob(File.join(stylesheets_dir, '*.scss')).each do |scss_file|
  css_file = scss_file.gsub('.scss', '.css')
  begin
    scss_content = File.read(scss_file)
    css_content = Sass::Engine.new(scss_content,
                                   syntax: :scss,
                                   load_paths: [stylesheets_dir] # ← This tells Sass where to find imports
                                  ).render
    File.write(css_file, css_content)
  rescue StandardError => e
    puts "Warning: Failed to compile #{File.basename(scss_file)}: #{e.message}"
  end
end
