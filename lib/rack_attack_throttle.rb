require_relative 'mongo_store'

Rack::Attack.cache.store = ActiveSupport::Cache::MongoStore.new(nil, collection: 'rack_attack_cache')

BOT_USER_AGENT_PATTERNS = %w[bot/ crawler/ indexer/ barkrowler/].freeze
PROTECTED_PATHS = %w[/events /search /o/the-psychedelic-society/events].freeze

Rack::Attack.throttle('bots and crawlers', limit: 60, period: 1.minute) do |request|
  request.user_agent if BOT_USER_AGENT_PATTERNS.any? { |pattern| request.user_agent.downcase.include?(pattern) } && PROTECTED_PATHS.any? { |path| request.path.starts_with?(path) }
end
