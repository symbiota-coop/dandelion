# The session lives in its cookie, which every response sends back whole (expire_after renews it each time), so of two
# requests in flight at once, the last to finish wins. A pagelet, poll, image or favicon the browser asked for before a
# click can finish after it and put back the session from before, losing the flash or sign in the click set. So a GET
# sends the session back only when it changed it, or when it's a page, which renews the expiry
class SessionCookieWrites
  def initialize(app)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)
    session = env['rack.session']
    return @app.call(env) unless session && (request.get? || request.head?)

    before = snapshot(session)
    status, headers, body = @app.call(env)
    page = !request.xhr? && headers['content-type'].to_s.start_with?('text/html')
    options = env['rack.session.options']
    options[:skip] = true unless page || snapshot(session) != before || options[:renew] || options[:drop]
    [status, headers, body]
  end

  private

  # Padrino's flash puts back an empty _flash on every request, which isn't a change. The session id only changes when
  # the session is renewed or dropped, which the options say, and is an object that never equals its copy
  def snapshot(session)
    session.to_hash.except('session_id').deep_dup.tap { |hash| hash.delete('_flash') if hash['_flash'].blank? }
  end
end
