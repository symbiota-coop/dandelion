# Event listings (/events and /o/:slug/events, as pages, results, map JSON and calendar feeds) are what crawlers spread
# over residential proxies hammer, each request a different filter from a different network, so neither Rack::Attack's
# throttles nor ASN blocking catch them. Each Puma process serves requests from a few threads, and when listings fill
# them all, event pages, checkout and sign in wait behind them: on 15 Nov 2026 a minute of them queued requests for 14s
# and Render answered 502 to everything until a second instance started. So each process runs at most LIMIT listing
# requests at once and turns the rest away at once with a 503 and Retry-After, keeping its other threads for the rest of
# the site. Signed-in sessions are never turned away. A page view makes its listing requests one after another (the
# page, then its results), so a visitor only meets the limit when listings are busier than any visitors make them.
# One who does, on a page they opened (or in an embed's frame), gets a page that reloads itself after Retry-After rather
# than an error
class ListingConcurrencyLimit
  # Puma's threads per process, as config/puma.rb sets them. RESERVED_THREADS of them are kept for the rest of the
  # site, but listings always get at least MIN_LIMIT, so one visitor's overlapping listing requests aren't turned away
  MAX_THREADS = Integer(ENV['MAX_THREADS'] || 3)
  RESERVED_THREADS = 3
  MIN_LIMIT = 2
  LIMIT = [MAX_THREADS - RESERVED_THREADS, MIN_LIMIT].max
  RETRY_AFTER_SECONDS = 10
  # Padrino serves each with a trailing slash and as .html too, so those count
  PATHS = [%r{\A/events(\.(html|ics|json))?/?\z}, %r{\A/o/[^/]+/events(\.(html|ics|json))?/?\z}].freeze
  BUSY_MESSAGE = 'Event listings are busy right now. Please try again in a few seconds.'.freeze
  # Only pages: feeds, JSON and XHR get BUSY_MESSAGE as text
  PAGE_EXTENSIONS = [nil, 'html'].freeze

  def initialize(app, limit: LIMIT)
    @app = app
    @limit = limit
    @running = 0
    @mutex = Mutex.new
  end

  def call(env)
    return @app.call(env) unless limited?(env)
    return busy(env) unless acquire

    begin
      @app.call(env)
    ensure
      release
    end
  end

  private

  def limited?(env)
    PATHS.any? { |pattern| env['PATH_INFO'].to_s.match?(pattern) } && !signed_in?(env)
  end

  # The session cookie is encrypted, so only a sign in can put an account_id there
  def signed_in?(env)
    session = env['rack.session']
    session.present? && session['account_id'].present?
  end

  def acquire
    @mutex.synchronize do
      next false if @running >= @limit

      @running += 1
      true
    end
  end

  def release
    @mutex.synchronize { @running -= 1 }
  end

  def busy(env)
    headers = { 'retry-after' => RETRY_AFTER_SECONDS.to_s }
    if page?(env)
      [503, headers.merge('content-type' => 'text/html; charset=utf-8'), [busy_page]]
    else
      [503, headers.merge('content-type' => 'text/plain'), [BUSY_MESSAGE]]
    end
  end

  # A page the browser opened, rather than a request a script or calendar app made
  def page?(env)
    extension = env['PATH_INFO'].to_s.chomp('/')[/\.(\w+)\z/, 1]
    PAGE_EXTENSIONS.include?(extension) && env['HTTP_X_REQUESTED_WITH'] != 'XMLHttpRequest' && env['HTTP_ACCEPT'].to_s.include?('text/html')
  end

  # Plain, so it costs nothing to serve: no layout, nothing loaded from the database
  def busy_page
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="refresh" content="#{RETRY_AFTER_SECONDS}">
      <title>Busy</title>
      </head>
      <body style="font-family: system-ui, sans-serif; margin: 2rem">
      <p>#{BUSY_MESSAGE} This page will reload by itself.</p>
      </body>
      </html>
    HTML
  end
end
