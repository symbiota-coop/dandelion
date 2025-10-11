require_relative 'mongo_store'

Rack::Attack.cache.store = ActiveSupport::Cache::MongoStore.new(nil, collection: 'rack_attack_cache')

PROTECTED_PATH_PATTERNS = [%r{^/search$}, %r{^/events$}, %r{^/events\.ics$}, %r{^/o/[a-z0-9-]+/events$}, %r{^/o/[a-z0-9-]+/events\.ics$}].freeze

# Completely block bots that try to use q parameter on protected paths
Rack::Attack.blocklist('crawlers on protected paths using q param') do |request|
  request.is_crawler? && PROTECTED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } && request.params['q']
end

# Throttle other bot/crawler requests to protected paths
Rack::Attack.throttle('crawlers on protected paths', limit: 1, period: 1.minute) do |request|
  request.user_agent if request.is_crawler? && PROTECTED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) }
end
