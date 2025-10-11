require_relative 'mongo_store'

Rack::Attack.cache.store = ActiveSupport::Cache::MongoStore.new(nil, collection: 'rack_attack_cache')

BOT_USER_AGENT_PATTERNS = %w[
  bot/ crawler/ /crawler indexer/ spider/ scraper/ spider-
].freeze
PROTECTED_PATH_PATTERNS = [%r{^/search$}, %r{^/events$}, %r{^/events\.ics$}, %r{^/o/[a-z0-9-]+/events$}, %r{^/o/[a-z0-9-]+/events\.ics$}].freeze

# Completely block bots that try to use q parameter on protected paths
Rack::Attack.blocklist('block bots using q param on protected paths') do |request|
  is_bot = request.user_agent && BOT_USER_AGENT_PATTERNS.any? { |pattern| request.user_agent.downcase.include?(pattern) }
  is_protected_path_with_q = PROTECTED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } && request.params['q']
  is_bot && is_protected_path_with_q
end

# Throttle other bot/crawler requests to protected paths
Rack::Attack.throttle('bots and crawlers', limit: 1, period: 1.minute) do |request|
  request.user_agent if BOT_USER_AGENT_PATTERNS.any? { |pattern| request.user_agent.downcase.include?(pattern) } && PROTECTED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) }
end
