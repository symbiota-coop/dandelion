require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# The site admins' stats pages (app/controllers/stats.rb) that no test of their subject covers: they're for site admins
# only, many show what people wrote, bought or were sent, and each loads for an admin. RubyGems, npm and GitHub, which
# the packages page asks, are faked; the delivery page has no Mailgun key here, so shows its error
class StatsPagesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  PAGES = %w[
    /stats/charts /stats/comments /stats/contributions /stats/delivery /stats/files /stats/icons /stats/messages
    /stats/openrouter /stats/orders /stats/organisations /stats/packages /stats/packages?tab=frontend
    /stats/packages?tab=actions /stats/referrals /stats/routes /stats/sentry_spans /stats/transactions /stats/traces
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
    covers_route 'GET /stats/routes', 'GET /stats/sentry_spans', 'GET /stats/transactions', 'GET /stats/traces'
    covers_route 'GET /stats/traces/:id', 'GET /stats/traces/slowest'
    create_trace_indexes
    trace = create_trace
    message_between_strangers('A private message')

    [nil, FactoryBot.create(:account)].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      without_package_registries do
        (PAGES + ["/stats/traces/#{trace.id}", '/stats/traces/slowest?name=GET+/e/:slug']).each do |path|
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
end
