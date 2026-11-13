# Browser tests don't reach the internet on each page load. Every page loads about 27 files from outside hosts, several
# pages a second, and a network that throttles new connections (as some office firewalls do) then fails jQuery's load at
# random, and with it every script on the page. So the browser's requests to outside hosts never leave the machine:
#
# - CACHED_HOSTS (jsDelivr, Google Fonts) are answered from tmp/cdn_cache, each file downloaded once, by URL, over one
#   connection per host, and kept for later runs. Its URLs name versions, so a file never changes; a file with a hash in
#   frontend/integrity.json must match it, or it isn't kept (the browser would refuse it too)
# - BLOCKED_URLS (Maps, Turnstile, Stripe.js, Iframely) fail at once. Tests have no keys for them, and pages work
#   without them: Maps show their could-not-load message, there's no captcha without RECAPTCHA_SITE_KEY, tests that
#   pay replace window.Stripe (record_stripe_redirect), and rich text shows embeds as links
#
# Any other outside host is still reached, with a warning once per run, so add it to one or the other
module CdnCache
  DIR = File.expand_path('../../tmp/cdn_cache', __dir__)

  CACHED_HOSTS = %w[cdn.jsdelivr.net fonts.googleapis.com fonts.gstatic.com].freeze

  BLOCKED_URLS = [
    # Tests have no Maps key, and Google's own scripts, which change weekly, can throw on the page and fail tests that
    # aren't about maps. Tests of places.js fake the Places library (FAKE_PLACES_JS in accounts/accounts_test.rb)
    %r{\Ahttps://maps\.googleapis\.com/},
    %r{\Ahttps://challenges\.cloudflare\.com/},
    %r{\Ahttps://js\.stripe\.com/},
    %r{\Ahttps://cdn\.iframe\.ly/}
  ].freeze

  # The request headers a download passes on, so Google Fonts answers with the same CSS it gives the browser
  FORWARDED_HEADERS = %w[User-Agent Accept Accept-Language].freeze

  @mutex = Mutex.new
  @connections = {}
  @warned_hosts = Set.new

  class << self
    # Answers a request the browser paused (Fetch.requestPaused) from the cache, blocks it, or lets it through
    def handle(request)
      uri = URI(request.url)
      if BLOCKED_URLS.any? { |pattern| request.match?(pattern) }
        request.abort
      elsif request.method == 'GET' && CACHED_HOSTS.include?(uri.host)
        respond(request, uri)
      else
        warn_once(uri.host)
        request.continue
      end
    rescue StandardError => e
      warn "CdnCache: #{request.url}: #{e.class}: #{e.message}"
      request.abort
    end

    private

    def respond(request, uri)
      entry = fetch(uri, request.headers)
      headers = { 'Content-Type' => entry[:content_type], 'Access-Control-Allow-Origin' => '*', 'Cache-Control' => 'public, max-age=31536000, immutable' }
      request.respond(responseCode: entry[:status], responseHeaders: headers, body: entry[:body])
    end

    # The file at uri, from the cache, or downloaded into it
    def fetch(uri, request_headers)
      path = File.join(DIR, Digest::SHA256.hexdigest(uri.to_s))
      cached = read(path)
      return cached if cached

      @mutex.synchronize do
        read(path) || download(uri, path, request_headers)
      end
    end

    def read(path)
      return unless File.exist?(path) && File.exist?("#{path}.json")

      meta = JSON.parse(File.read("#{path}.json"))
      { status: 200, content_type: meta['content_type'], body: File.binread(path) }
    end

    def download(uri, path, request_headers)
      response = get(uri, request_headers)
      body = response.body.to_s.b
      content_type = response['Content-Type'] || 'application/octet-stream'
      return { status: response.code.to_i, content_type: content_type, body: body } unless response.is_a?(Net::HTTPOK)

      check_integrity(uri, body)
      FileUtils.mkdir_p(DIR)
      # Written to a temporary file and renamed, so test runs at the same time never read half a file
      write = lambda do |file, content|
        temporary = "#{file}.#{Process.pid}.tmp"
        File.binwrite(temporary, content)
        File.rename(temporary, file)
      end
      write.call(path, body)
      write.call("#{path}.json", JSON.generate(url: uri.to_s, content_type: content_type))
      { status: 200, content_type: content_type, body: body }
    end

    def check_integrity(uri, body)
      expected = FRONTEND_INTEGRITY[uri.to_s]
      return unless expected

      actual = "sha384-#{Digest::SHA384.base64digest(body)}"
      raise "#{uri} doesn't match its hash in frontend/integrity.json" unless actual == expected
    end

    # GETs uri over the host's one connection, through HTTPS_PROXY when it's set (cloud agents), trying 3 times
    def get(uri, request_headers)
      headers = request_headers.slice(*FORWARDED_HEADERS)
      attempts = 0
      begin
        attempts += 1
        connection(uri).request(Net::HTTP::Get.new(uri, headers))
      rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
        @connections.delete(uri.host)&.then { |http| http.finish if http.started? }
        raise if attempts >= 3

        sleep attempts
        retry
      end
    end

    def connection(uri)
      @connections[uri.host] ||= begin
        proxy = uri.find_proxy
        http = Net::HTTP.new(uri.host, uri.port, proxy&.host, proxy&.port, proxy&.user, proxy&.password)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 30
        http.start
      end
    end

    def warn_once(host)
      return if host.nil? || %w[127.0.0.1 localhost].include?(host) || @warned_hosts.include?(host)

      @warned_hosts << host
      warn "CdnCache: a browser test reached #{host}: add it to CdnCache::CACHED_HOSTS or BLOCKED_URLS (test/setup/cdn_cache.rb)"
    end
  end

  # Each page the driver opens (windows and tabs too) sends its requests to outside hosts to CdnCache.handle. Only https
  # is paused: the app under test is served over http, so its own requests go straight through
  module Page
    private

    def prepare_page
      super
      network.intercept(pattern: 'https://*')
      on(:request) { |request| CdnCache.handle(request) }
    end
  end
end

Capybara::Cuprite::Page.prepend(CdnCache::Page)
