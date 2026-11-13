require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# The site's routes that answer programs and pagelets, or refuse forged requests: health checks, error pages, MCP
# sessions, icons, maps and their popups, uploads, YouTube thumbnails, the Stripe row splitter, and who may send
# feedback and questions, claim referral rewards, mark their messages and notifications checked and search their network
class SiteRoutesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze
  SVG = '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>'.freeze

  def uploaded(data, filename, type)
    file = Tempfile.new(['upload', File.extname(filename)], binmode: true)
    file.write(data)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, true, original_filename: filename)
  end

  def without_imagemagick(&)
    Dragonfly.app.shell.stub(:run, ->(command, *) { flunk "ran #{command}" }, &)
  end

  def point_path(model_name, id)
    "/points/#{model_name}/#{TokenEncryptor.encrypt("map:#{model_name}:#{id}")}"
  end

  # Health and errors

  test "the health check answers 200 and isn't counted as a page view" do
    covers_route 'GET /health'
    get '/health'
    assert_equal 200, last_response.status
    assert_equal 0, PageView.count
  end

  test 'the error and not found pages render, and a path no route matches is a 404 with the not found page' do
    covers_route 'GET /error', 'GET /not_found'
    get '/error'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Uhoh! Something went wrong.'

    get '/not_found'
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Hmm, we couldn't find that page."

    get '/no-such-page'
    assert_equal 404, last_response.status
    assert_includes last_response.body, "Hmm, we couldn't find that page."
  end

  # MCP

  test 'MCP is stateless: GET opens no stream and DELETE ends no session, and both refuse a bad key' do
    covers_route 'GET /mcp', 'DELETE /mcp'
    header 'Accept', 'text/event-stream'
    get '/mcp'
    assert_equal 405, last_response.status
    assert_equal 'Method not allowed', JSON.parse(last_response.body).dig('error', 'message')

    delete '/mcp'
    assert_equal 200, last_response.status
    assert_equal({ 'success' => true }, JSON.parse(last_response.body))

    header 'Authorization', 'Bearer not-a-real-key'
    get '/mcp'
    assert_equal 401, last_response.status
    delete '/mcp'
    assert_equal 401, last_response.status
    assert_equal 'invalid_token', JSON.parse(last_response.body)['error']
  end

  # Icons and JSON

  test 'calendar icons draw a month and day, refusing anything else' do
    covers_route 'GET /icons/calendar/:month/:day'
    get '/icons/calendar/jan/5'
    assert_equal 200, last_response.status
    assert_equal 'image/svg+xml', last_response.media_type
    assert_includes last_response.body, '>JAN<'
    assert_includes last_response.body, '>5<'

    ['/icons/calendar/janu/5', '/icons/calendar/jan/123', '/icons/calendar/j%3Cn/5'].each do |path|
      get path
      assert_equal 400, last_response.status, path
    end
  end

  test 'image icons are only the SVGs in the icons folder' do
    covers_route 'GET /icons/image/:image'
    get '/icons/image/link'
    assert_equal 200, last_response.status
    assert_equal 'image/svg+xml', last_response.media_type
    assert_includes last_response.body, '<svg'

    ['/icons/image/no-such-icon', '/icons/image/..%2F..%2Fapp', '/icons/image/LINK'].each do |path|
      get path
      assert_equal 404, last_response.status, path
    end
  end

  test 'the wheel of the year lists the festivals and when they fall in each hemisphere' do
    covers_route 'GET /wheel-of-the-year.json'
    get '/wheel-of-the-year.json'
    assert_equal 200, last_response.status
    wheel = JSON.parse(last_response.body)
    assert_equal(ALMANAC_FESTIVALS.map { |festival| festival[:id].to_s }, wheel['festivals'].map { |festival| festival['id'] })
    assert_equal %w[north south], wheel['timeline'].keys
    wheel['timeline'].each_value do |timeline|
      assert timeline.any?
      assert(timeline.all? { |entry| Time.iso8601(entry['at']) && wheel['festivals'].any? { |festival| festival['id'] == entry['id'] } })
    end
  end

  # Maps

  test "the homepage's map starts straight away, showing events, and the map trigger answers 200" do
    covers_route 'GET /map/home', 'GET /map/trigger'
    get '/map/home'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'url: "/events"'
    assert_includes last_response.body, 'fillScreen: true'
    refute_includes last_response.body, 'Click to view map'

    get '/map/trigger'
    assert_equal 200, last_response.status
  end

  test "a map point's popup shows an event, and a person only if their location is public" do
    covers_route 'GET /points/:model/:id'
    create_event(name: 'Map Meetup')
    get point_path('Event', @event.id)
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Map Meetup'

    shown = FactoryBot.create(:account, name: 'Pia Public', location_privacy: 'Public', has_signed_in: true)
    get point_path('Account', shown.id)
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Pia Public'

    unshown = FactoryBot.create(:account, name: 'Fay Followed', location_privacy: 'People I follow', has_signed_in: true)
    get point_path('Account', unshown.id)
    assert_equal 403, last_response.status
    get point_path('Organisationship', FactoryBot.create(:organisationship, account: unshown).id)
    assert_equal 403, last_response.status

    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    get point_path('Account', unshown.id)
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Fay Followed'
  end

  test "a map point's id must be one a map gave out, for the model it names, of a model maps show" do
    covers_route 'GET /points/:model/:id'
    create_event
    token = TokenEncryptor.encrypt("map:Event:#{@event.id}")
    ["/points/Event/#{@event.id}", "/points/Organisation/#{token}", "/points/Event/#{token}x", point_path('Ticket', BSON::ObjectId.new)].each do |path|
      get path
      assert_equal 400, last_response.status, path
    end
  end

  # Uploads

  test 'someone signed in uploads an image for the editor, stored as a JPEG of theirs' do
    covers_route 'POST /upload'
    account = FactoryBot.create(:account)
    sign_in_with_rack(account)
    post '/upload', { upload: uploaded(File.binread('app/assets/images/coop.png'), 'coop.png', 'image/png') }, XHR
    assert_equal 200, last_response.status
    url = JSON.parse(last_response.body)['default']
    upload = Upload.last
    assert_equal account.id, upload.account_id
    assert_equal 'jpeg', upload.file.format
    assert_equal upload.file.url, url
  end

  test "uploads refuse files that aren't images, before ImageMagick sees them, and anyone signed out" do
    covers_route 'POST /upload'
    sign_in_with_rack(FactoryBot.create(:account))
    [[SVG, 'drawing.svg', 'image/svg+xml'], [SVG, 'drawing.jpg', 'image/jpeg'], ['hello', 'notes.txt', 'text/plain']].each do |data, filename, type|
      without_imagemagick { post '/upload', { upload: uploaded(data, filename, type) }, XHR }
      assert_equal 422, last_response.status, filename
      assert_equal 'Only images can be uploaded', JSON.parse(last_response.body).dig('error', 'message')
    end
    assert_equal 0, Upload.count

    clear_cookies
    post '/upload', { upload: uploaded(File.binread('app/assets/images/coop.png'), 'coop.png', 'image/png') }, XHR
    assert_equal 403, last_response.status
    assert_equal 0, Upload.count
  end

  # YouTube thumbnails

  # MiniMagick fetching YouTube's thumbnails: served, from the app's test image, for the sizes listed, and a 404 for
  # others. Gives the URLs asked for
  def stub_youtube(served)
    requested = []
    original = MiniMagick::Image.method(:open)
    opener = lambda do |path, *args|
      return original.call(path, *args) unless path.start_with?('https://')

      requested << path
      raise OpenURI::HTTPError.new('404 Not Found', StringIO.new) unless served.any? { |size| path.end_with?("/#{size}.jpg") }

      original.call('app/assets/images/test-event.jpg')
    end
    MiniMagick::Image.stub(:open, opener) { yield }
    requested
  end

  test "YouTube thumbnails are the video's thumbnail, cropped to 16:9 with a play button, falling back to the smaller one" do
    covers_route 'GET /youtube_thumb/:id'
    requested = stub_youtube(%w[sddefault hqdefault]) { get '/youtube_thumb/dQw4w9WgXcQ' }
    assert_equal 200, last_response.status
    assert_equal 'image/jpeg', last_response.media_type
    assert_equal [640, 360], MiniMagick::Image.read(last_response.body).dimensions
    assert_equal ['https://i.ytimg.com/vi/dQw4w9WgXcQ/sddefault.jpg'], requested

    requested = stub_youtube(%w[hqdefault]) { get '/youtube_thumb/dQw4w9WgXcQ' }
    assert_equal 200, last_response.status
    assert_equal %w[sddefault hqdefault].map { |size| "https://i.ytimg.com/vi/dQw4w9WgXcQ/#{size}.jpg" }, requested

    stub_youtube([]) { get '/youtube_thumb/dQw4w9WgXcQ' }
    assert_equal 404, last_response.status
  end

  test "YouTube thumbnails refuse anything that isn't a video id, fetching nothing" do
    covers_route 'GET /youtube_thumb/:id'
    ['/youtube_thumb/short', '/youtube_thumb/dQw4w9WgXcQ1', '/youtube_thumb/dQw4w9W.XcQ'].each do |path|
      requested = stub_youtube(%w[sddefault]) { get path }
      assert_equal 400, last_response.status, path
      assert_empty requested
    end
  end

  # The Stripe row splitter

  test 'the Stripe row splitter takes a CSV, with no sign in, and gives back its rows split by ticket type' do
    covers_route 'GET /stripe_row_splitter', 'POST /stripe_row_splitter'
    get '/stripe_row_splitter'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'name="csv"'

    description = 'Bach Cantatas, Tue 3 Feb 2026, 19:00 at St Mary, London: Standard £10x2, Concession £5x1'
    csv = CSV.generate { |rows| rows << %w[id Description Amount Currency] << ['ch_1', description, '25.00', 'gbp'] }
    post '/stripe_row_splitter', csv: uploaded(csv, 'payments.csv', 'text/csv')
    assert_equal 200, last_response.status
    assert_equal 'text/csv', last_response.media_type
    assert_equal [%w[id Description Amount Currency],
                  ['ch_1', 'Bach Cantatas, Tue 3 Feb 2026, 19:00 at St Mary, London: Standard £10x2', '20.00', 'gbp'],
                  ['ch_1', 'Bach Cantatas, Tue 3 Feb 2026, 19:00 at St Mary, London: Concession £5x1', '5.00', 'gbp']], CSV.parse(last_response.body)

    post '/stripe_row_splitter', csv: 'not a file'
    assert_equal 400, last_response.status
  end

  # Feedback, questions and referrals

  test 'feedback and questions need someone signed in, and something to send' do
    covers_route 'POST /feedback', 'POST /docs/question'
    account = FactoryBot.create(:account)
    emails = with_env('FOUNDER_EMAIL' => 'founder@example.com') do
      recorded_emails do
        post '/feedback', feedback: 'Hello'
        assert_equal 302, last_response.status
        post '/docs/question', question: 'Hello?'
        assert_equal 302, last_response.status

        sign_in_with_rack(account)
        post '/feedback'
        assert_equal 400, last_response.status
        post '/docs/question'
        assert_equal 400, last_response.status
      end
    end
    # Only signing in's own email
    assert_empty(emails.select { |email| email.recipients.include?('founder@example.com') })
  end

  test "a referral reward can't be claimed by someone else, for too little, or twice" do
    covers_route 'POST /referrals/:id/claim'
    admin = FactoryBot.create(:account, admin: true)
    referrer = FactoryBot.create(:account)
    create_organisation(referrer: referrer)
    contribution = @organisation.organisation_contributions.create!(amount: 50, currency: 'EUR', payment_completed: true)

    emails = recorded_emails do
      post "/referrals/#{@organisation.id}/claim"
      assert_equal 302, last_response.status

      sign_in_with_rack(@account)
      post "/referrals/#{@organisation.id}/claim"
      assert_equal 404, last_response.status

      sign_in_with_rack(referrer)
      post "/referrals/#{@organisation.id}/claim"
      assert_equal 400, last_response.status

      contribution.set(amount: 200)
      @organisation.set(reward_claimer_id: @account.id)
      post "/referrals/#{@organisation.id}/claim"
      assert_equal 400, last_response.status
    end
    # Only signing in's own emails
    assert_empty(emails.select { |email| email.recipients.include?(admin.email) })
    assert_equal @account.id, @organisation.reload.reward_claimer_id
  end

  # Messages, notifications and the network

  test 'checking messages and notifications marks only the signed-in account, and clears only its notifications' do
    covers_route 'POST /checked_messages', 'POST /checked_notifications'
    account = FactoryBot.create(:account)
    other = FactoryBot.create(:account)
    [account, other].each { |a| Fragment.create!(key: "/notifications?account_id=#{a.id}", value: 'cached', expires: 1.hour.from_now) }

    post '/checked_messages', {}, XHR
    assert_equal 403, last_response.status
    post '/checked_notifications', {}, XHR
    assert_equal 403, last_response.status

    sign_in_with_rack(account)
    post '/checked_messages', { account_id: other.id }, XHR
    assert_equal 200, last_response.status
    post '/checked_notifications', { account_id: other.id }, XHR
    assert_equal 200, last_response.status

    account.reload
    other.reload
    assert account.last_checked_messages
    assert account.last_checked_notifications
    assert_nil other.last_checked_messages
    assert_nil other.last_checked_notifications
    assert_nil Fragment.find_by(key: "/notifications?account_id=#{account.id}")
    assert Fragment.find_by(key: "/notifications?account_id=#{other.id}")
  end

  test 'mentioning someone searches only the people one follows' do
    covers_route 'GET /network'
    account = FactoryBot.create(:account)
    followed = FactoryBot.create(:account, name: 'Bea Followed')
    FactoryBot.create(:account, name: 'Bea Stranger')
    Follow.create!(follower: account, followee: followed)

    get '/network', { q: 'Bea' }, XHR
    assert_equal 403, last_response.status

    sign_in_with_rack(account)
    get '/network', { q: 'Bea' }, XHR
    assert_equal 200, last_response.status
    assert_equal([{ 'key' => 'Bea Followed', 'value' => followed.username }], JSON.parse(last_response.body).map { |person| person.slice('key', 'value') })
  end
end
