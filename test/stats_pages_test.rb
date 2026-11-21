require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# The site admins' stats pages (app/controllers/stats.rb) that no test of their subject covers: they're for site admins
# only, many show what people wrote, bought or were sent, and each loads for an admin. RubyGems, npm and GitHub, which
# the packages page asks, are faked; the delivery page has no Mailgun key here, so shows its error
class StatsPagesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  PAGES = %w[
    /stats/charts /stats/comments /stats/contributions /stats/delivery /stats/donations /stats/files /stats/icons /stats/images /stats/messages
    /stats/openrouter /stats/orders /stats/organisations /stats/packages /stats/packages?tab=frontend
    /stats/packages?tab=actions /stats/referrals /stats/routes /stats/sentry_spans /stats/spring_clean /stats/transactions
    /stats/traces
  ].freeze

  # Trace.summary hints its index, which a query fails without, and the releases' one is read the same way in production
  def create_trace_indexes
    Trace.collection.indexes.create_one(Trace::SUMMARY_INDEX)
    Trace.collection.indexes.create_one(Trace::RELEASES_INDEX)
  end

  def create_trace(name: 'GET /e/:slug', duration_ms: 1500, release: 'a' * 40, committed_at: 1.day.ago)
    # As Sentry sends them, compacted as the app stores them
    started = Time.now.to_f
    spans = Trace.compact_spans([{ 'span_id' => 's1', 'op' => 'db', 'description' => 'find events', 'status' => 'ok',
                                   'start_timestamp' => started, 'timestamp' => started + 0.0125 }], started)
    Trace.create!(name: name, started_at: Time.now, duration_ms: duration_ms, span_count: spans.length, http_status: 200,
                  release: release, release_committed_at: committed_at, spans_zstd: Trace.pack_spans(spans))
  end

  def message_between_strangers(body)
    messenger, messengee = FactoryBot.create_list(:account, 2)
    messenger.set(email_confirmed: true, can_message: true)
    Message.create!(messenger: messenger, messengee: messengee, body: body)
  end

  # RubyGems', npm's and GitHub's answers, for the packages page: none has anything newer to say
  def without_package_registries(&)
    response = Faraday::Response.new(status: 404, body: '', response_headers: {})
    Faraday.stub(:get, ->(*) { response }, &)
  end

  test "the stats pages are for site admins only, and show none of what they hold to anyone else" do
    covers_route 'GET /stats/charts', 'GET /stats/comments', 'GET /stats/contributions', 'GET /stats/delivery'
    covers_route 'GET /stats/files', 'GET /stats/icons', 'GET /stats/messages', 'GET /stats/openrouter'
    covers_route 'GET /stats/orders', 'GET /stats/organisations', 'GET /stats/packages', 'GET /stats/referrals'
    covers_route 'GET /stats/routes', 'GET /stats/sentry_spans', 'GET /stats/spring_clean', 'GET /stats/transactions'
    covers_route 'GET /stats/traces', 'GET /stats/donations'
    covers_route 'GET /stats/traces/:id', 'GET /stats/traces/slowest'
    create_trace_indexes
    trace = create_trace
    message_between_strangers('A private message')

    [nil, FactoryBot.create(:account)].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      without_package_registries do
        (PAGES + ["/stats/traces/#{trace.id}", '/stats/traces/slowest?name=GET+/e/:slug', '/raise', '/raise_job', '/geolocate']).each do |path|
          get path
          assert last_response.redirect?, "#{path} for #{account ? 'an account' : 'someone signed out'}"
          refute_includes last_response.body, 'A private message', path
        end
      end
    end
  end

  test "only a site admin deletes old traces, and only those of releases before the one chosen" do
    covers_route 'POST /stats/traces/delete_before'
    create_trace_indexes
    old = create_trace(release: 'a' * 40, committed_at: 3.days.ago)
    middle = create_trace(release: 'b' * 40, committed_at: 2.days.ago)
    latest = create_trace(release: 'c' * 40, committed_at: 1.day.ago)

    sign_in_with_rack(FactoryBot.create(:account))
    post '/stats/traces/delete_before', release: 'c' * 40
    assert last_response.redirect?
    assert_equal 3, Trace.count

    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    post '/stats/traces/delete_before', release: 'unknown'
    assert_equal 400, last_response.status
    post '/stats/traces/delete_before', release: 'b' * 40
    assert_equal '/stats/traces', URI(last_response.location).path
    assert_nil Trace.find(old.id)
    assert Trace.find(middle.id)
    assert Trace.find(latest.id)
  end

  test "a site admin opens a route's slowest trace, and an unknown route's is not found" do
    covers_route 'GET /stats/traces/slowest'
    create_trace_indexes
    create_trace(duration_ms: 800)
    slowest = create_trace(duration_ms: 2400)
    create_trace(name: 'GET /o/:slug', duration_ms: 9000)

    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    get '/stats/traces/slowest', name: 'GET /e/:slug'
    assert_equal "/stats/traces/#{slowest.id}", URI(last_response.location).path
    get '/stats/traces/slowest', name: 'GET /nowhere'
    assert_equal 404, last_response.status
  end

  test 'a site admin sees each stats page' do
    covers_route 'GET /stats/traces/:id'
    create_trace_indexes
    trace = create_trace
    message_between_strangers('A message for the stats')
    OpenRouterGeneration.create!(model: 'test/model', source: 'test', prompt: 'A prompt', response: 'A response')
    Fragment.create!(key: 'monthly_contributions', expires: 1.day.from_now, value: [['November 2026', 120, { 'stripe_charges' => 100 }]].to_json)
    sign_in(FactoryBot.create(:account, admin: true))

    without_package_registries do
      (PAGES + ["/stats/traces/#{trace.id}"]).each do |path|
        visit path
        # A JavaScript error on the page fails the test too (Cuprite's js_errors)
        assert_equal 200, page.status_code, path
      end
    end
    visit '/stats/messages'
    assert page.has_content?('A message for the stats')
    visit '/stats/contributions'
    assert page.has_css?('canvas')
    assert_includes page.html, 'November 2026'
    visit "/stats/traces/#{trace.id}"
    assert page.has_content?('find events')
  end

  def donate_at_checkout(event, amount, to_dandelion: true, paid: true, at: Time.now)
    donor = FactoryBot.create(:account)
    order = event.orders.create!(account: donor, currency: 'GBP', value: amount, payment_completed: paid, application_fee_paid_to_dandelion: to_dandelion)
    event.donations.create!(account: donor, order: order, amount: amount, payment_completed: paid).tap { |donation| donation.set(created_at: at) }
  end

  test 'Donations lists the events whose checkouts raised the most for Dandelion in the dates chosen, the past three months by default' do
    covers_route 'GET /stats/donations'
    create_event(name: 'Smaller Event', as: :smaller)
    create_event(name: 'Bigger Event', as: :bigger)
    create_event(name: 'Older Event', as: :older)
    create_event(name: 'Other Event', as: :other)
    donate_at_checkout(@smaller, 5)
    donate_at_checkout(@bigger, 12)
    donate_at_checkout(@bigger, 8, at: 1.month.ago)
    donate_at_checkout(@older, 50, at: 4.months.ago)
    # Donations to the event's organisers, and unpaid ones
    donate_at_checkout(@other, 100, to_dandelion: false)
    donate_at_checkout(@other, 100, paid: false)
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/donations'
    assert page.has_content?('2 events raised £25 in 3 donations to Dandelion at checkout')
    assert_equal ['Bigger Event', 'Smaller Event'], all('#donations tbody td:first-child a').map(&:text)
    assert page.has_css?('#donations tr', text: /Bigger Event.*2\s+£20/)
    assert page.has_no_link?('Older Event')
    assert page.has_no_link?('Other Event')

    execute_script "document.querySelector('[name=from]')._flatpickr.setDate(#{5.months.ago.to_date.iso8601.to_json})"
    click_on 'Search'
    assert page.has_content?('3 events raised £75 in 4 donations to Dandelion at checkout')
    assert_equal ['Older Event', 'Bigger Event', 'Smaller Event'], all('#donations tbody td:first-child a').map(&:text)
  end

  test 'Donations and Organisations list only the top 100, but count them all' do
    covers_route 'GET /stats/donations', 'GET /stats/organisations'
    events = (1..101).map do |i|
      FactoryBot.create(:event, name: "Event #{i}", organisation: FactoryBot.create(:organisation, name: "Organisation #{i}"))
    end
    events.each_with_index { |event, i| donate_at_checkout(event, i + 1) }
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/donations'
    assert page.has_content?('101 events raised')
    assert page.has_content?('The top 100 events are listed')
    assert_equal 100, all('#donations tbody tr').count
    assert page.has_link?('Event 2')
    assert page.has_no_link?('Event 1', exact: true)

    visit '/stats/organisations'
    assert page.has_content?('101 organisations sold')
    assert page.has_content?('The top 100 organisations are listed')
    assert_equal 100, all('#summary tbody tr').count
    assert page.has_link?('Organisation 2')
    assert page.has_no_link?('Organisation 1', exact: true)
  end

  test 'Spring clean lists the organisations over a year old and gatherings over a month old that nobody uses, and deletes nothing' do
    covers_route 'GET /stats/spring_clean'
    old = 2.months.ago
    older = 2.years.ago
    unused_organisation = FactoryBot.create(:organisation, name: 'Unused Organisation')
    with_event = FactoryBot.create(:organisation, name: 'With An Event')
    FactoryBot.create(:event, organisation: with_event)
    # Through a polymorphic association
    with_code = FactoryBot.create(:organisation, name: 'With A Discount Code')
    with_code.discount_codes.create!(code: 'SPRING', percentage_discount: 10)
    with_image = FactoryBot.create(:organisation, name: 'With An Image')
    with_image.set(image_uid: 'image')
    with_follower = FactoryBot.create(:organisation, name: 'With Another Follower')
    with_follower.organisationships.create!(account: FactoryBot.create(:account))
    [unused_organisation, with_event, with_code, with_image, with_follower].each { |organisation| organisation.set(created_at: older) }
    FactoryBot.create(:organisation, name: 'Months Old Organisation').set(created_at: old)

    unused_gathering = FactoryBot.create(:gathering, name: 'Unused Gathering')
    with_member = FactoryBot.create(:gathering, name: 'With Another Member')
    with_member.memberships.create!(account: FactoryBot.create(:account))
    with_option = FactoryBot.create(:gathering, name: 'With An Option')
    with_option.options.create!(name: 'Tent', type: 'Accommodation', account: with_option.account)
    unlisted = FactoryBot.create(:gathering, name: 'Unlisted Gathering', listed: false)
    [unused_gathering, with_member, with_option, unlisted].each { |gathering| gathering.set(created_at: old) }
    FactoryBot.create(:gathering, name: 'New Gathering')
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/spring_clean'
    assert page.has_link? 'Unused Organisation', href: "/o/#{unused_organisation.slug}"
    assert page.has_link? 'Unused Gathering', href: "/g/#{unused_gathering.slug}"
    ['With An Event', 'With A Discount Code', 'With An Image', 'With Another Follower', 'Months Old Organisation',
     'With Another Member', 'With An Option', 'Unlisted Gathering', 'New Gathering'].each do |name|
      assert page.has_no_link?(name), name
    end
    assert Organisation.find(unused_organisation.id)
    assert Gathering.find(unused_gathering.id)
  end

  test 'a site admin raises a test error, in a request or a job, to check errors are reported' do
    covers_route 'GET /raise', 'GET /raise_job'
    sign_in_with_rack(FactoryBot.create(:account, admin: true))

    error = assert_raises(RuntimeError) { get '/raise', message: 'Checking error reporting' }
    assert_equal 'Checking error reporting', error.message

    reported = []
    ErrorReporting.stub(:capture_exception, ->(exception, context: nil, **) { reported << [exception.message, context]; nil }) do
      get '/raise', message: 'Checking context', detail: 'more'
    end
    assert_equal 200, last_response.status
    assert_equal [['Checking context', { detail: 'more' }]], reported

    # Tests run jobs as they're enqueued, so the job's error comes straight back
    error = assert_raises(RuntimeError) { get '/raise_job', message: 'Checking the worker' }
    assert_equal 'Checking the worker', error.message
    assert_includes error.backtrace.join, 'delayed'
  end

  test "a site admin sees where their address is, or why it couldn't be found" do
    covers_route 'GET /geolocate'
    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    reader = Object.new
    reader.define_singleton_method(:city) { |ip| { 'ip' => ip, 'city' => 'Stockholm' } }

    MaxMinder.stub(:reader, reader) { get '/geolocate', {}, 'HTTP_CF_CONNECTING_IP' => '81.2.69.142' }
    assert_equal({ 'ip' => '81.2.69.142', 'city' => 'Stockholm' }, JSON.parse(last_response.body))

    # No GeoLite database, as on a machine that hasn't downloaded it
    MaxMinder.stub(:reader, nil) { get '/geolocate', {}, 'HTTP_CF_CONNECTING_IP' => '81.2.69.142' }
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'city'
  end
end
