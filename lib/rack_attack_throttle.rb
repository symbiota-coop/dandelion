require_relative 'mongo_store'

Rack::Attack.cache.store = ActiveSupport::Cache::MongoStore.new(nil, collection: 'rack_attack_cache')

BOT_USER_AGENT_PATTERNS = %w[bot crawler indexer spider scraper].map { |pattern| ["/#{pattern}", "#{pattern}/", "-#{pattern}", "#{pattern}-"] }.flatten.freeze
PROTECTED_PATH_PATTERNS = [%r{^/search$}, %r{^/events$}, %r{^/events\.ics$}, %r{^/o/[a-z0-9-]+/events$}, %r{^/o/[a-z0-9-]+/events\.ics$}].freeze

bot_request = ->(request) { request.user_agent && BOT_USER_AGENT_PATTERNS.any? { |pattern| request.user_agent.downcase.include?(pattern) } }
protected_path = ->(request) { PROTECTED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } }

Rack::Attack.blocklist('block bots on protected paths using search') do |request|
  bot_request.call(request) && protected_path.call(request) && (request.params['q'] || request.params['search'])
end

Rack::Attack.throttle('throttle bots on protected paths', limit: 1, period: 1.minute) do |request|
  "#{request.user_agent}:#{request.path}" if bot_request.call(request) && protected_path.call(request)
end

Rack::Attack.blocklist('js redirect') do |request|
  protected_path.call(request) && (request.params['q'] || request.params['search']) && request.referer.nil?
end

Rack::Attack.blocklisted_responder = lambda do |request|
  if request.env['rack.attack.matched'] == 'js redirect'
    escaped_uri = request.env['REQUEST_URI'].to_json
    [403, { 'Content-Type' => 'text/html' }, ["<script>window.location = #{escaped_uri};</script>"]]
  else
    [403, {}, ['Forbidden']]
  end
end
