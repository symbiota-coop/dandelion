require_relative '../test_config'

# ASN blocking: the app never blocks a request itself. It keeps a Cloudflare WAF rule (ip.src.asnum eq ...) listing
# the blocked networks, which Cloudflare enforces at the edge. Asn.autoblock (the hourly errands) lists ASNs whose
# traffic surged over the baseline network's and blocks those Cloudflare Radar counts as mostly bots; site admins
# block, unblock and mark ASNs legit at /stats/asns. Cloudflare's API answers here from Faraday test stubs, which
# raise on any request they don't stub, so nothing reaches the network
class IntegrationsAsnBlockingTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze
  CLOUDFLARE_ENV = { 'CLOUDFLARE_ZONE_ID' => 'zone', 'CLOUDFLARE_RULESET_ID' => 'ruleset', 'CLOUDFLARE_ASN_RULE_ID' => 'asnrule', 'FOUNDER_EMAIL' => 'founder@example.com' }.freeze
  RULESET_PATH = '/client/v4/zones/zone/rulesets/ruleset'.freeze
  RULE_PATH = '/client/v4/zones/zone/rulesets/ruleset/rules/asnrule'.freeze
  BASELINE = Asn::BASELINE_ASN.to_s
  # 14:30 in Stockholm: the last complete 1-hour window is 13:00-14:00 (11:00Z), and the last complete 3-hour one 09:00-12:00
  NOW = Time.utc(2026, 6, 10, 12, 30)
  IN_LAST_HOUR = '2026-06-10T11:00:00Z'.freeze

  setup do
    @saved_env = CLOUDFLARE_ENV.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    ENV.update(CLOUDFLARE_ENV)
    travel_to NOW
  end

  teardown do
    travel_back
    @saved_env.each { |key, value| ENV[key] = value }
  end

  def rule(*asns)
    { 'id' => 'asnrule', 'action' => 'block', 'description' => 'Blocked ASNs', 'expression' => asns.map { |a| "(ip.src.asnum eq #{a})" }.join(' or ') }
  end

  def row(asn, count, hour: IN_LAST_HOUR, description: "AS#{asn} network")
    { 'count' => count, 'dimensions' => { 'datetimeHour' => hour, 'clientAsn' => asn, 'clientASNDescription' => description } }
  end

  # Answers Cloudflare's API for the block: the ruleset holds rule_answer's rule (nil for none), analytics answers rows,
  # Radar answers bot % (bot) and country and name (details: { asn => [country, name, confidence] }). Yields what's
  # recorded: the bodies of the rule PATCHes, and the ASNs Radar was asked about
  def with_cloudflare(rule_answer: rule('1'), rows: [], bot: {}, details: {}, patch_answer: { 'success' => true }, ruleset_status: 200)
    calls = { patches: [], radar: [] }
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(RULESET_PATH) do
        [ruleset_status, JSON_HEADERS, { success: ruleset_status == 200, result: { rules: [rule_answer].compact } }.to_json]
      end
      stub.patch(RULE_PATH) do |env|
        calls[:patches] << JSON.parse(env.body)
        [200, JSON_HEADERS, patch_answer.to_json]
      end
      stub.post('/client/v4/graphql') do
        [200, JSON_HEADERS, { data: { viewer: { zones: [{ httpRequestsAdaptiveGroups: rows }] } } }.to_json]
      end
      stub.get(%r{\A/client/v4/radar/http/summary/bot_class}) do |env|
        asn = env.params['asn']
        calls[:radar] << asn
        summary = bot.key?(asn) ? { summary_0: { bot: bot[asn].to_s, human: (100 - bot[asn]).to_s } } : {}
        [200, JSON_HEADERS, { result: summary }.to_json]
      end
      stub.get(%r{\A/client/v4/radar/entities/asns/}) do |env|
        country, name, confidence = details[env.url.path.split('/').last]
        [200, JSON_HEADERS, { result: { asn: { country: country, name: name, confidenceLevel: confidence || 10 } } }.to_json]
      end
    end
    connection = Faraday.new(url: 'https://api.cloudflare.com') do |f|
      f.response :json
      f.adapter :test, stubs
    end
    Asn.stub(:conn, connection) { yield calls }
  end

  def autoblock
    emails = nil
    capture_io { emails = recorded_emails { Asn.autoblock } }
    emails
  end

  def mark_legit(*asns)
    Stash.create!(key: 'legit_asns', value: asns.join(','))
  end

  test 'the blocked ASNs are the ones in the rule, and none without a rule' do
    assert_equal %w[13335 64500], Asn.blocked_asns(rule('13335', '64500'))
    assert_equal [], Asn.blocked_asns(nil)
  end

  test 'the legit ASNs are the stashed list, and none without one' do
    assert_equal [], Asn.legit_asns
    mark_legit('64500', ' 64501')
    assert_equal %w[64500 64501], Asn.legit_asns
  end

  test "the bot % bar is the country's threshold over the ratio, never under the floor" do
    assert_equal 50, Asn.autoblock_bot_threshold('DE')
    assert_equal 50, Asn.autoblock_bot_threshold(nil)
    assert_equal 25, Asn.autoblock_bot_threshold('CN')
    assert_equal 75, Asn.autoblock_bot_threshold('SE')
    assert_in_delta 25.0, Asn.autoblock_bot_bar('DE', 2.0)
    assert_in_delta 37.5, Asn.autoblock_bot_bar('SE', 2.0)
    assert_in_delta 100.0, Asn.autoblock_bot_bar('DE', 0.5)
    assert_in_delta 20.0, Asn.autoblock_bot_bar('DE', 10.0)
  end

  test 'the big clouds are never autoblocked by name' do
    assert Asn.skip_autoblock_for_description?('Google LLC')
    assert Asn.skip_autoblock_for_description?(' Amazon.com, Inc. ')
    refute Asn.skip_autoblock_for_description?('Hetzner Online GmbH')
    refute Asn.skip_autoblock_for_description?(nil)
    refute Asn.skip_autoblock_for_description?(' ')
  end

  test 'a window lists the ASNs over listed_from times the baseline, but not the baseline, legit ASNs or the big clouds' do
    rows = [
      row(BASELINE, 1000), row('111', 1600), row('222', 1400),
      row('333', 5000), row('444', 5000, description: 'Google LLC'),
      # In the hour still running, so not in a complete window
      row(BASELINE, 1000, hour: '2026-06-10T12:00:00Z'), row('555', 9000, hour: '2026-06-10T12:00:00Z')
    ]
    windows = Asn.suspicious_windows(rows: rows, hours: 1, legit_asns: ['333'], window_length: 1, listed_from: 1.5, threshold: 3.0)

    assert_equal 1, windows.size
    window = windows.first
    assert_equal Time.utc(2026, 6, 10, 11), window[:start].utc
    assert_equal 1000, window[:baseline]
    assert_equal(['111'], window[:asns].map { |r| r['asn'] })
    assert_in_delta 1600.0 / 3000, window[:asns].first['ratio']
  end

  test 'windows before 6am and windows whose baseline is under its minimum list nothing' do
    rows = [
      # 03:00 in Stockholm
      row(BASELINE, 1000, hour: '2026-06-10T01:00:00Z'), row('666', 9000, hour: '2026-06-10T01:00:00Z'),
      # 10:00, one request under the baseline's minimum
      row(BASELINE, Asn::MIN_BASELINE_PER_HOUR - 1, hour: '2026-06-10T08:00:00Z'), row('777', 9000, hour: '2026-06-10T08:00:00Z'),
      # 11:00, at the minimum
      row(BASELINE, Asn::MIN_BASELINE_PER_HOUR, hour: '2026-06-10T09:00:00Z'), row('888', 400, hour: '2026-06-10T09:00:00Z')
    ]
    windows = Asn.suspicious_windows(rows: rows, hours: 12, legit_asns: [], window_length: 1, listed_from: 1.5, threshold: 3.0)

    assert_equal([['888']], windows.map { |w| w[:asns].map { |r| r['asn'] } })
  end

  test 'autoblock blocks the surging ASNs over their bot bar in one rule update, and tells the founder' do
    rows = [row(BASELINE, 1000), row('64500', 6000), row('64501', 6000), row('64502', 6000)]
    details = { '64500' => ['DE', 'Botnet Hosting', 9], '64501' => ['DE', 'Some ISP', 9], '64502' => ['SE', 'Swedish ISP', 9] }
    # At twice the threshold, the bar is 25% in Germany and 37.5% in Sweden
    bot = { '64500' => 30, '64501' => 20, '64502' => 30 }
    with_cloudflare(rule_answer: rule('1'), rows: rows, bot: bot, details: details) do |calls|
      emails = autoblock

      assert_equal [{ 'expression' => '(ip.src.asnum eq 1) or (ip.src.asnum eq 64500)', 'action' => 'block', 'description' => 'Blocked ASNs' }], calls[:patches]
      assert_equal 1, emails.size
      assert_equal ['founder@example.com'], emails.first.recipients
      assert_equal '[ASN blocked] 64500 (30.0% bot)', emails.first.subject_line
    end
  end

  test "autoblock counts an ASN's country only when Radar is confident of it" do
    rows = [row(BASELINE, 1000), row('64502', 6000)]
    # Unsure it's Swedish, so it's held to the default bar (25% here), not Sweden's (37.5%)
    with_cloudflare(rows: rows, bot: { '64502' => 30 }, details: { '64502' => ['SE', 'Swedish ISP', 4] }) do |calls|
      autoblock
      assert_equal '(ip.src.asnum eq 1) or (ip.src.asnum eq 64502)', calls[:patches].first['expression']
    end
  end

  test 'autoblock never blocks a legit ASN, however many bots' do
    mark_legit('64500')
    with_cloudflare(rows: [row(BASELINE, 1000), row('64500', 50_000)], bot: { '64500' => 100 }) do |calls|
      emails = autoblock

      assert_empty calls[:patches]
      assert_empty calls[:radar]
      assert_empty emails
    end
  end

  test 'autoblock never blocks the big clouds, by their analytics description or their Radar name' do
    rows = [row(BASELINE, 1000), row('16509', 50_000, description: 'Amazon.com, Inc.'), row('8075', 50_000, description: 'MICROSOFT-CORP')]
    with_cloudflare(rows: rows, bot: { '16509' => 100, '8075' => 100 }, details: { '8075' => ['US', 'Microsoft Corporation', 10] }) do |calls|
      autoblock

      assert_empty calls[:patches]
      assert_equal ['8075'], calls[:radar]
    end
  end

  test 'autoblock leaves the rule alone for an ASN already blocked, and when the baseline network is quiet' do
    with_cloudflare(rule_answer: rule('64500'), rows: [row(BASELINE, 1000), row('64500', 50_000)], bot: { '64500' => 100 }) do |calls|
      autoblock
      assert_empty calls[:patches]
      assert_empty calls[:radar]
    end

    with_cloudflare(rows: [row(BASELINE, Asn::MIN_BASELINE_PER_HOUR - 1), row('64500', 50_000)], bot: { '64500' => 100 }) do |calls|
      autoblock
      assert_empty calls[:patches]
    end
  end

  test "autoblock blocks nothing and reports the error when it can't read the rule" do
    reported = []
    with_cloudflare(ruleset_status: 500, rows: [row(BASELINE, 1000), row('64500', 50_000)], bot: { '64500' => 100 }) do |calls|
      ErrorReporting.stub(:capture_exception, ->(e, **) { reported << e }) { autoblock }

      assert_empty calls[:patches]
      assert_equal 1, reported.size
    end
  end

  test 'autoblock reports a rule update Cloudflare refuses, and tells no one of a block' do
    reported = []
    with_cloudflare(rows: [row(BASELINE, 1000), row('64500', 50_000)], bot: { '64500' => 100 }, patch_answer: { 'success' => false, 'errors' => ['bad'] }) do |calls|
      emails = nil
      ErrorReporting.stub(:capture_exception, ->(e, **) { reported << e }) { emails = autoblock }

      assert_equal 1, calls[:patches].size
      assert_empty emails
      assert_match 'failed to update Cloudflare rule', reported.first.message
    end
  end

  test 'the ASN pages and actions are for site admins only' do
    account = FactoryBot.create(:account)
    with_cloudflare(rule_answer: rule('1', '64500')) do |calls|
      [nil, account].each do |viewer|
        viewer ? sign_in_with_rack(viewer) : clear_cookies
        get '/stats/asns'
        assert last_response.redirect?
        post '/stats/asns/block/64501'
        assert last_response.redirect?
        post '/stats/asns/unblock/64500'
        assert last_response.redirect?
        post '/stats/asns/legit/64500'
        assert last_response.redirect?
      end

      assert_empty calls[:patches]
      assert_empty Asn.legit_asns
    end
  end

  test 'a site admin blocks and unblocks an ASN in the rule' do
    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    with_cloudflare(rule_answer: rule('1', '64500')) do |calls|
      post '/stats/asns/block/64501'
      assert_equal '/stats/asns', URI(last_response.location).path
      # Already blocked: no update
      post '/stats/asns/block/64500'
      assert_equal '/stats/asns', URI(last_response.location).path
      post '/stats/asns/unblock/64500'
      assert_equal '/stats/asns', URI(last_response.location).path

      assert_equal(['(ip.src.asnum eq 1) or (ip.src.asnum eq 64500) or (ip.src.asnum eq 64501)', '(ip.src.asnum eq 1)'], calls[:patches].map { |p| p['expression'] })
      assert_equal ['block'], calls[:patches].map { |p| p['action'] }.uniq
    end
  end

  test "blocking and unblocking refuse when there's no rule, and unblocking won't empty it" do
    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    with_cloudflare(rule_answer: nil) do |calls|
      post '/stats/asns/block/64500'
      assert_equal 400, last_response.status
      post '/stats/asns/unblock/64500'
      assert_equal 400, last_response.status
      assert_empty calls[:patches]
    end

    with_cloudflare(rule_answer: rule('64500')) do |calls|
      post '/stats/asns/unblock/64500'
      assert_equal 400, last_response.status
      assert_empty calls[:patches]
    end
  end

  test "an ASN that isn't a number is refused, so it can't add a clause to the rule" do
    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    with_cloudflare(rule_answer: rule('64500', '64501')) do |calls|
      ['1) or (true', 'AS64502', '64502 ', '-1'].each do |asn|
        post "/stats/asns/block/#{ERB::Util.url_encode(asn)}"
        assert_equal 400, last_response.status, asn
        post "/stats/asns/unblock/#{ERB::Util.url_encode(asn)}"
        assert_equal 400, last_response.status, asn
        post "/stats/asns/legit/#{ERB::Util.url_encode(asn)}"
        assert_equal 400, last_response.status, asn
      end
      assert_empty calls[:patches]
      assert_empty Asn.legit_asns
    end
  end

  test 'a site admin marks an ASN legit and unmarks it' do
    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    post '/stats/asns/legit/64500'
    assert_equal '/stats/asns', URI(last_response.location).path
    post '/stats/asns/legit/64501'
    assert_equal %w[64500 64501], Asn.legit_asns
    post '/stats/asns/legit/64500'
    assert_equal %w[64501], Asn.legit_asns
  end

  test 'a site admin sees the suspicious, blocked and legit ASNs' do
    mark_legit('64999')
    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    rows = [row(BASELINE, 1000), row('64501', 6000, description: 'Surging Hosting')]
    with_cloudflare(rule_answer: rule('64500'), rows: rows, bot: { '64501' => 40 }, details: { '64500' => ['NL', 'Blocked Hosting', 9] }) do
      get '/stats/asns'
      assert last_response.ok?
      assert_includes last_response.body, 'Surging Hosting'
      assert_includes last_response.body, '/stats/asns/block/64501'
      assert_includes last_response.body, '/stats/asns/unblock/64500'
      assert_includes last_response.body, '/stats/asns/legit/64999'
    end
  end
end
