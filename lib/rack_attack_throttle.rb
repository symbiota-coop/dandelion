require_relative 'mongo_store'

Rack::Attack.cache.store = ActiveSupport::Cache::MongoStore.new(nil, collection: 'rack_attack_cache')

BOT_USER_AGENT_PATTERNS = %w[
  bot/ crawler/ /crawler indexer/ spider/ scraper/ spider-
].freeze
PROTECTED_PATHS = %w[/search /events /events.ics /o/the-psychedelic-society/events /o/the-psychedelic-society/events.ics].freeze

bot_request = ->(request) { request.user_agent && BOT_USER_AGENT_PATTERNS.any? { |pattern| request.user_agent.downcase.include?(pattern) } }
protected_path = ->(request) { PROTECTED_PATHS.include?(request.path) }

Rack::Attack.blocklist('crawlers on protected paths using q param') do |request|
  bot_request.call(request) && protected_path.call(request) && request.params['q']
end

Rack::Attack.throttle('crawlers on protected paths', limit: 1, period: 1.minute) do |request|
  "#{request.user_agent}:#{request.path}" if bot_request.call(request) && protected_path.call(request)
end
