require_relative 'mongo_store'

Rack::Attack.cache.store = ActiveSupport::Cache::MongoStore.new(nil, collection: 'rack_attack_cache')

BOT_USER_AGENT_PATTERNS = %w[bot crawler indexer spider scraper].map { |pattern| ["/#{pattern}", "#{pattern}/", "-#{pattern}", "#{pattern}-"] }.flatten.freeze
BLOCKED_PATH_PATTERNS = [%r{^/search$}, %r{^/events$}, %r{^/o/[a-z0-9-]+/events$}].freeze
THROTTLED_PATH_PATTERNS = BLOCKED_PATH_PATTERNS + [%r{^/events\.ics$}, %r{^/o/[a-z0-9-]+/events\.ics$}].freeze

# SQL injection / attack patterns in headers
MALICIOUS_HEADER_PATTERNS = [
  /sleep\s*\(/i,                    # sleep() SQL injection
  /sysdate\s*\(/i,                  # Oracle sysdate()
  /DBMS_PIPE/i,                     # Oracle DBMS_PIPE
  /\bfrom\s+DUAL\b/i,               # Oracle DUAL table
  /\bselect\s*\(/i,                 # SQL select
  /XOR\s*\(/i,                      # XOR-based injection
  /%25[0-9a-f]{2}/i,                # Double URL-encoded chars
  /['"].*['"]$/,                    # Trailing quote injection (e.g. XMLHttpRequest'")
  /\|\|/                            # SQL concatenation operator
].freeze

BLOCK_BOTS_USING_SEARCH = 'block bots using search'.freeze
JS_CHALLENGE = 'js challenge'.freeze
MALICIOUS_HEADER = 'malicious header'.freeze

bot_request = ->(request) { request.user_agent && BOT_USER_AGENT_PATTERNS.any? { |pattern| request.user_agent.downcase.include?(pattern) } }
blocked_path = ->(request) { BLOCKED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } }
throttled_path = ->(request) { THROTTLED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } }
malicious_header = lambda do |request|
  xhr = request.env['HTTP_X_REQUESTED_WITH']
  xhr && xhr != 'XMLHttpRequest' && MALICIOUS_HEADER_PATTERNS.any? { |pattern| xhr.match?(pattern) }
end

# 🚫 Block IPs for 6 hours if they send malicious X-Requested-With headers
Rack::Attack.blocklist(MALICIOUS_HEADER) do |request|
  Rack::Attack::Fail2Ban.filter("malicious-header:#{request.ip}", maxretry: 0, findtime: 6.hours, bantime: 6.hours) do
    malicious_header.call(request)
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
  when MALICIOUS_HEADER
    [403, {}, ['Forbidden']]
  end
end

Rack::Attack.throttle('throttle bots', limit: 1, period: 1.minute) do |request|
  "#{request.user_agent}:#{request.path}" if throttled_path.call(request) && bot_request.call(request)
end
