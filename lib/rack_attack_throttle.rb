require_relative 'mongo_store'

Rack::Attack.cache.store = ActiveSupport::Cache::MongoStore.new(nil, collection: 'rack_attack_cache')

BOT_USER_AGENT_PATTERNS = %w[bot crawler indexer spider scraper].map { |pattern| ["/#{pattern}", "#{pattern}/", "-#{pattern}", "#{pattern}-"] }.flatten.freeze
BLOCKED_PATH_PATTERNS = [%r{^/search$}, %r{^/events$}, %r{^/o/[a-z0-9-]+/events$}].freeze
THROTTLED_PATH_PATTERNS = BLOCKED_PATH_PATTERNS + [%r{^/events\.ics$}, %r{^/o/[a-z0-9-]+/events\.ics$}].freeze

# Characters not expected in valid X-Requested-With values (XMLHttpRequest or Android package names)
INVALID_XHR_HEADER_CHARS = %r{[^A-Za-z0-9_./-]}

BLOCK_BOTS_USING_SEARCH = 'block bots using search'.freeze
JS_CHALLENGE = 'js challenge'.freeze
INVALID_XHR_HEADER = 'invalid xhr header'.freeze

bot_request = ->(request) { request.user_agent && BOT_USER_AGENT_PATTERNS.any? { |pattern| request.user_agent.downcase.include?(pattern) } }
blocked_path = ->(request) { BLOCKED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } }
throttled_path = ->(request) { THROTTLED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } }
invalid_xhr_header = lambda do |request|
  xhr = request.env['HTTP_X_REQUESTED_WITH']
  xhr && xhr != 'XMLHttpRequest' && xhr.match?(INVALID_XHR_HEADER_CHARS)
end
real_ip = ->(request) { request.env['HTTP_CF_CONNECTING_IP'] || request.ip }

Rack::Attack.blocklist(INVALID_XHR_HEADER) do |request|
  key = "invalid-xhr:#{real_ip.call(request)}"

  if invalid_xhr_header.call(request)
    Rack::Attack.cache.store.write(key, true, expires_in: 6.hours)
    true
  else
    Rack::Attack.cache.store.read(key)
  end
end

Rack::Attack.blocklist(BLOCK_BOTS_USING_SEARCH) do |request|
  blocked_path.call(request) && (request.params['q'] || request.params['search']) && bot_request.call(request)
end

Rack::Attack.blocklist(JS_CHALLENGE) do |request|
  blocked_path.call(request) && (request.params['q'] || request.params['search']) && request.referer.nil?
end

Rack::Attack.blocklisted_responder = lambda do |request|
  case request.env['rack.attack.matched']
  when BLOCK_BOTS_USING_SEARCH
    [403, {}, ['Forbidden']]
  when JS_CHALLENGE
    escaped_uri = request.env['REQUEST_URI'].to_json
    [403, { 'Content-Type' => 'text/html' }, ["<script>window.location = #{escaped_uri};</script>"]]
  when INVALID_XHR_HEADER
    [403, {}, ['Forbidden']]
  end
end

Rack::Attack.throttle('throttle bots', limit: 1, period: 1.minute) do |request|
  "#{request.user_agent}:#{request.path}" if throttled_path.call(request) && bot_request.call(request)
end
