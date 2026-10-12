# Defines our constants
RACK_ENV = ENV['RACK_ENV'] ||= 'development' unless defined?(RACK_ENV)
PADRINO_ROOT = File.expand_path('..', __dir__) unless defined?(PADRINO_ROOT)
EMAIL_REGEX = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
MAP_POINTS_LIMIT = 1000
# The default theme colour, Dandelion's green (--color-green-500 in app.css)
DEFAULT_THEME_COLOR = '#00af5e'
CACHEBUST_DIGESTS = {}
LIBRARY_CACHE = {}
ADJECTIVES = %w[soulful regenerative metamodern participatory conscious transformative holistic ethical].freeze

# Each test run gets its own database, which test_config.rb drops afterwards, and a free port, so runs at the
# same time (in one checkout or several) can't wipe each other's data or clash on the port
if RACK_ENV == 'test'
  require 'socket'
  ENV['TEST_DATABASE'] = "dandelion_test_#{Process.pid}"
  # Capybara binds the port seconds later, so a port the OS picks now could be taken by another run by then.
  # Instead, each run takes the first free port in its own block of 10, set by its process ID
  port_free = lambda do |port|
    TCPServer.new('127.0.0.1', port).close
    true
  rescue Errno::EADDRINUSE, Errno::EACCES
    false
  end
  block = 10_000 + ((Process.pid % 4000) * 10)
  port = (block...(block + 10)).find(&port_free)
  raise "No free port in #{block}-#{block + 9}" unless port
  ENV['PORT'] = port.to_s
  ENV['BASE_URI'] = "http://127.0.0.1:#{ENV['PORT']}"
end

# Load our dependencies
require 'rubygems' unless defined?(Gem)
require 'bundler/setup'
require 'open-uri'
require 'active_support/time'
require 'active_support/security_utils'
require 'will_paginate/array'
require 'will_paginate/mongoid'
require 'csv'
Bundler.require(:default, RACK_ENV)

Mongoid.load!("#{PADRINO_ROOT}/config/mongoid.yml")
Mongoid.raise_not_found_error = false
Mongoid.autosave_saves_unchanged_documents = false

# Padrino loads each glob shallow-first, so models/*.rb would run before
# models/concerns and every model would NameError on CoreExtensions and reload.
models_glob = Padrino.dependency_paths.index("#{Padrino.root}/models/**/*.rb") || Padrino.dependency_paths.length
Padrino.dependency_paths.insert(models_glob, "#{Padrino.root}/models/concerns/**/*.rb")

require_relative 'test_safe_load' if Padrino.env == :test

Padrino.load!

require_relative 'sentry_config'
require_relative 'dragonfly_config'
require_relative 'frontend_dependencies'

OmniAuth.config.allowed_request_methods = [:get]
OmniAuth.config.logger = Logger.new(IO::NULL)

Delayed::Worker.max_attempts = 1
Delayed::Worker.max_run_time = 15.minutes
Delayed::Worker.destroy_failed_jobs = false

# Cost 12 takes ~275 ms a hash, and every account the test factory creates hashes a password.
# The cost is stored in each hash, so hashes made here still verify anywhere
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST if %i[test development].include?(Padrino.env)

Money.default_currency = ENV['DEFAULT_CURRENCY']
Money.default_bank = DandelionBank.new
Money.locale_backend = :currency
Money.rounding_mode = BigDecimal::ROUND_HALF_UP

if Padrino.env == :production
  begin
    MaxMinder.download
    MaxMinder.reader
  rescue StandardError => e
    ErrorReporting.capture_exception(e)
  end
end

Time.zone = ENV['DEFAULT_TIME_ZONE']

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
