Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV['REDIS_URL'])

BOT_USER_AGENT_PATTERNS = %w[bot crawler indexer spider scraper].map { |pattern| ["/#{pattern}", "#{pattern}/", "-#{pattern}", "#{pattern}-"] }.flatten.freeze
BLOCKED_PATH_PATTERNS = [%r{^/search$}, %r{^/events$}, %r{^/o/[a-z0-9-]+/events$}].freeze
THROTTLED_PATH_PATTERNS = BLOCKED_PATH_PATTERNS + [%r{^/events\.ics$}, %r{^/o/[a-z0-9-]+/events\.ics$}].freeze
BLOCKED_IP_PREFIXES = ENV['BLOCKED_IP_PREFIXES']&.split(',')&.map(&:strip) || []

# Characters not expected in valid X-Requested-With values (XMLHttpRequest or Android package names)
INVALID_XHR_HEADER_CHARS = %r{[^A-Za-z0-9_./-]}

BLOCK_BOTS_USING_SEARCH = 'block bots using search'.freeze
JS_CHALLENGE = 'js challenge'.freeze
INVALID_XHR_HEADER = 'invalid xhr header'.freeze
BLOCKED_IP_RANGE = 'blocked ip range'.freeze

bot_request = ->(request) { request.user_agent && BOT_USER_AGENT_PATTERNS.any? { |pattern| request.user_agent.downcase.include?(pattern) } }
blocked_path = ->(request) { BLOCKED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } }
throttled_path = ->(request) { THROTTLED_PATH_PATTERNS.any? { |pattern| request.path.match?(pattern) } }
deepwiki_question = ->(request) { request.post? && request.path == '/docs/deepwiki' }
deepwiki_fetch = ->(request) { request.get? && request.path.match?(%r{\A/docs/ask/[^/]+(?:/answer\.json)?\z}) }
signed_in = ->(request) { request.session[:account_id].present? }
filtered_listing = lambda do |request|
  request.params['q'] || request.params['search'] || request.params['carousel_ids']
end
invalid_xhr_header = lambda do |request|
  xhr = request.env['HTTP_X_REQUESTED_WITH']
  xhr && xhr != 'XMLHttpRequest' && xhr.match?(INVALID_XHR_HEADER_CHARS)
end
real_ip = ->(request) { request.env['HTTP_CF_CONNECTING_IP'] || request.env['HTTP_X_FORWARDED_FOR'] || request.ip }

Rack::Attack.blocklist(BLOCKED_IP_RANGE) do |request|
  BLOCKED_IP_PREFIXES.any? { |prefix| real_ip.call(request)&.start_with?(prefix) }
end

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
  blocked_path.call(request) && filtered_listing.call(request) && bot_request.call(request)
end

Rack::Attack.blocklist(JS_CHALLENGE) do |request|
  blocked_path.call(request) && filtered_listing.call(request) && request.referer.nil?
end

Rack::Attack.blocklisted_responder = lambda do |request|
  case request.env['rack.attack.matched']
  when BLOCKED_IP_RANGE
    [403, {}, ["Forbidden: Your IP range has been blocked due to suspicious activity. Please email #{ENV['CONTACT_EMAIL']} if you believe you have received this message in error."]]
  when BLOCK_BOTS_USING_SEARCH
    [403, {}, ["Forbidden: Bots are not permitted to use search features. Please email #{ENV['CONTACT_EMAIL']} if you believe you have received this message in error."]]
  when JS_CHALLENGE
    json_uri = request.env['REQUEST_URI'].to_s.to_json
    escaped_uri = ERB::Util.json_escape(json_uri)
    [403, { 'Content-Type' => 'text/html' }, ["<script>window.location = #{escaped_uri};</script>"]]
  when INVALID_XHR_HEADER
    [403, {}, ["Forbidden: Malicious request headers detected. Your IP has been temporarily blocked. Please email #{ENV['CONTACT_EMAIL']} if you believe you have received this message in error."]]
  end
end

Rack::Attack.throttle('throttle bots', limit: 1, period: 1.hour) do |request|
  "#{request.user_agent}:#{request.path}" if throttled_path.call(request) && bot_request.call(request)
end

throttle_deepwiki = lambda do |name, match, guests:, accounts:|
  guest_limit, guest_period = guests
  account_limit, account_period = accounts

  Rack::Attack.throttle("deepwiki #{name} globally", limit: guest_limit, period: guest_period) do |request|
    'global' if match.call(request) && !signed_in.call(request)
  end

  Rack::Attack.throttle("deepwiki #{name} signed in", limit: account_limit, period: account_period) do |request|
    request.session[:account_id] if match.call(request)
  end
end

throttle_deepwiki.call('questions', deepwiki_question, guests: [15, 1.minute], accounts: [30, 1.minute])
throttle_deepwiki.call('question volume', deepwiki_question, guests: [100, 1.hour], accounts: [200, 1.hour])
throttle_deepwiki.call('fetch burst', deepwiki_fetch, guests: [50, 5.seconds], accounts: [100, 5.seconds])
throttle_deepwiki.call('fetch volume', deepwiki_fetch, guests: [600, 1.minute], accounts: [1200, 1.minute])
