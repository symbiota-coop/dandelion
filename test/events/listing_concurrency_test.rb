require_relative '../test_config'

# ListingConcurrencyLimit: each process runs at most LIMIT signed-out listing requests at once and turns the rest away
# with a 503, so a crawl of the listings leaves threads for the rest of the site. Requests are held inside the route by
# making Event.live wait, as a slow listing query would, from separate Rack sessions on their own threads
class EventListingConcurrencyTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # Runs the block while LIMIT signed-out /events requests are held inside the route, then lets them finish, returning
  # their responses
  def while_listings_are_full
    gate = Queue.new
    arrived = Queue.new
    held = 0
    held_mutex = Mutex.new
    live = Event.method(:live)
    hold = lambda do |*args|
      first = held_mutex.synchronize { (held += 1) <= ListingConcurrencyLimit::LIMIT }
      if first
        arrived << true
        gate.pop
      end
      live.call(*args)
    end

    responses = []
    Event.stub(:live, hold) do
      threads = Array.new(ListingConcurrencyLimit::LIMIT) do
        Thread.new { Rack::Test::Session.new(app).get('/events').tap { |response| responses << response } }
      end
      ListingConcurrencyLimit::LIMIT.times { Timeout.timeout(10) { arrived.pop } }
      begin
        yield
      ensure
        ListingConcurrencyLimit::LIMIT.times { gate << true }
        threads.each { |thread| thread.join(10) }
      end
    end
    responses
  end

  test 'listings beyond the limit are turned away at once while the rest of the site is served' do
    create_event
    held_responses = while_listings_are_full do
      get '/events'
      assert_equal 503, last_response.status
      assert_equal ListingConcurrencyLimit::RETRY_AFTER_SECONDS.to_s, last_response.headers['retry-after']
      assert_equal ListingConcurrencyLimit::BUSY_MESSAGE, last_response.body

      get "/o/#{@organisation.slug}/events", event_tag_id: BSON::ObjectId.new.to_s
      assert_equal 503, last_response.status
      get "/o/#{@organisation.slug}/events.ics"
      assert_equal 503, last_response.status
      # The other URLs Padrino serves the listings at
      ['/events/', '/events.html', '/events.json/', "/o/#{@organisation.slug}/events/", "/o/#{@organisation.slug}/events.html"].each do |path|
        get path
        assert_equal 503, last_response.status, path
      end

      get "/e/#{@event.slug}"
      assert_equal 200, last_response.status
      assert_includes last_response.body, @event.name
    end

    assert_equal [200] * ListingConcurrencyLimit::LIMIT, held_responses.map(&:status)
    get '/events'
    assert_equal 200, last_response.status
  end

  test 'a page a browser opens is turned away with a page that reloads itself, and scripts and feeds with text' do
    create_event
    browser = { 'HTTP_ACCEPT' => 'text/html,application/xhtml+xml,*/*;q=0.8' }
    while_listings_are_full do
      ['/events', "/o/#{@organisation.slug}/events", "/o/#{@organisation.slug}/events.html", '/events/'].each do |path|
        get path, {}, browser
        assert_equal 503, last_response.status, path
        assert_equal ListingConcurrencyLimit::RETRY_AFTER_SECONDS.to_s, last_response.headers['retry-after'], path
        assert_includes last_response.content_type, 'text/html', path
        assert_includes last_response.body, %(<meta http-equiv="refresh" content="#{ListingConcurrencyLimit::RETRY_AFTER_SECONDS}">), path
        assert_includes last_response.body, ListingConcurrencyLimit::BUSY_MESSAGE, path
      end

      # A pagelet's XHR asks for HTML too, but isn't a page to reload
      get "/o/#{@organisation.slug}/events", {}, browser.merge('HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest')
      assert_equal 503, last_response.status
      assert_equal ListingConcurrencyLimit::BUSY_MESSAGE, last_response.body
      ["/o/#{@organisation.slug}/events.ics", '/events.json'].each do |path|
        get path, {}, browser
        assert_equal 503, last_response.status, path
        assert_equal ListingConcurrencyLimit::BUSY_MESSAGE, last_response.body, path
      end
    end
  end

  test 'signed-in sessions are not turned away when listings are full' do
    create_event
    sign_in_with_rack(@account)
    while_listings_are_full do
      get "/o/#{@organisation.slug}/events.ics"
      assert_equal 200, last_response.status
      assert_includes last_response.body, @event.name
    end
  end
end
