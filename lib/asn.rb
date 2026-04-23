module Asn
  BASELINE_ASN = 2856
  WINDOW_LENGTH = 3
  THRESHOLD = 1
  TIMEZONE = 'Europe/Stockholm'

  AUTOBLOCK_BOT_PCT_DEFAULT = 50
  AUTOBLOCK_BOT_PCT_LOW = 25
  AUTOBLOCK_BOT_PCT_LOW_COUNTRIES = %w[CN RU IN ID VN HK SG MX ZA BR].freeze
  AUTOBLOCK_BOT_PCT_HIGH = 75
  AUTOBLOCK_BOT_PCT_HIGH_COUNTRIES = %w[SE GB].freeze

  def self.autoblock_bot_threshold(country)
    return AUTOBLOCK_BOT_PCT_HIGH if AUTOBLOCK_BOT_PCT_HIGH_COUNTRIES.include?(country)
    AUTOBLOCK_BOT_PCT_LOW_COUNTRIES.include?(country) ? AUTOBLOCK_BOT_PCT_LOW : AUTOBLOCK_BOT_PCT_DEFAULT
  end

  def self.conn
    Faraday.new(url: 'https://api.cloudflare.com') { |f| f.response :json }
  end

  def self.fetch_rule
    detail = conn.get("/client/v4/zones/#{ENV['CLOUDFLARE_ZONE_ID']}/rulesets/#{ENV['CLOUDFLARE_RULESET_ID']}") do |req|
      req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
    end.body
    detail['success'] && detail['result']['rules']&.find { |r| r['id'] == ENV['CLOUDFLARE_ASN_RULE_ID'] }
  end

  def self.blocked_asns(rule)
    rule ? rule['expression'].scan(/ip\.src\.asnum eq (\d+)/).flatten : []
  end

  def self.legit_asns
    Stash.find_by(key: 'legit_asns')&.value&.split(',')&.map(&:strip) || []
  end

  def self.fetch_analytics(hours:)
    since = (Time.now.utc - (hours * 3600)).strftime('%Y-%m-%dT%H:%M:%SZ')
    query = <<~GRAPHQL
      {
        viewer {
          zones(filter: {zoneTag: "#{ENV['CLOUDFLARE_ZONE_ID']}"}) {
            httpRequestsAdaptiveGroups(
              filter: {datetime_geq: "#{since}", cacheStatus: "dynamic", edgeResponseStatus: 200}
              limit: 10000
              orderBy: [count_DESC]
            ) {
              count
              dimensions {
                datetimeHour
                clientAsn
                clientASNDescription
              }
            }
          }
        }
      }
    GRAPHQL
    resp = conn.post('/client/v4/graphql') do |req|
      req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
      req.headers['Content-Type'] = 'application/json'
      req.body = { query: query }.to_json
    end.body
    resp.dig('data', 'viewer', 'zones', 0, 'httpRequestsAdaptiveGroups') || []
  end

  def self.fetch_country_data(hours:)
    since = (Time.now.utc - (hours * 3600)).strftime('%Y-%m-%dT%H:%M:%SZ')
    query = <<~GRAPHQL
      {
        viewer {
          zones(filter: {zoneTag: "#{ENV['CLOUDFLARE_ZONE_ID']}"}) {
            httpRequestsAdaptiveGroups(
              filter: {datetime_geq: "#{since}", cacheStatus: "dynamic", edgeResponseStatus: 200}
              limit: 500
              orderBy: [count_DESC]
            ) {
              count
              dimensions {
                clientAsn
                clientCountryName
              }
            }
          }
        }
      }
    GRAPHQL
    resp = conn.post('/client/v4/graphql') do |req|
      req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
      req.headers['Content-Type'] = 'application/json'
      req.body = { query: query }.to_json
    end.body
    resp.dig('data', 'viewer', 'zones', 0, 'httpRequestsAdaptiveGroups') || []
  end

  def self.suspicious_windows(rows:, hours:, legit_asns:)
    windows = []
    tz = TZInfo::Timezone.get(TIMEZONE)
    now = tz.to_local(Time.now.utc)
    window_start = tz.local_time(now.year, now.month, now.day, (now.hour / WINDOW_LENGTH) * WINDOW_LENGTH) - (hours * 3600)
    while window_start < now
      window_end = window_start + (WINDOW_LENGTH * 3600)

      window_rows = rows.select do |r|
        t = Time.parse(r.dig('dimensions', 'datetimeHour'))
        t >= window_start && t < window_end
      end

      by_asn = window_rows.group_by { |r| r.dig('dimensions', 'clientAsn') }.map do |asn, rs|
        { 'asn' => asn, 'description' => rs.first.dig('dimensions', 'clientASNDescription'), 'count' => rs.sum { |r| r['count'] } }
      end
      next window_start = window_end if window_start.hour < 6 || window_end > now

      baseline_count = by_asn.find { |r| r['asn'].to_s == BASELINE_ASN.to_s }&.dig('count') || 0
      filtered = by_asn.select { |r| r['asn'].to_s != BASELINE_ASN.to_s && r['count'] > baseline_count * THRESHOLD && !legit_asns.include?(r['asn'].to_s) }.sort_by { |r| -r['count'] }

      windows << { start: window_start, end: window_end, baseline: baseline_count, asns: filtered } if filtered.any?
      window_start = window_end
    end
    windows.reverse!
    windows
  end

  def self.fetch_bot_classifications(asns)
    bot_pct = {}
    mutex = Mutex.new
    c = conn
    asns.map do |asn|
      Thread.new do
        response = c.get("/client/v4/radar/http/summary/bot_class?asn=#{asn}&dateRange=7d&format=json") do |req|
          req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
        end.body
        summary = response.dig('result', 'summary_0') || {}
        bot = summary['bot']&.to_f
        human = summary['human']&.to_f
        mutex.synchronize { bot_pct[asn] = { bot: bot&.round(1), human: human&.round(1) } } if bot && human
      end
    end.each(&:join)
    bot_pct
  end

  def self.fetch_asn_details(asns)
    countries = {}
    names = {}
    mutex = Mutex.new
    c = conn
    asns.uniq.map do |asn|
      Thread.new do
        response = c.get("/client/v4/radar/entities/asns/#{asn}") do |req|
          req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
        end.body
        details = response.dig('result', 'asn') || {}
        country = details['country']
        confidence = details['confidenceLevel'].to_i
        next unless confidence >= 5

        mutex.synchronize do
          countries[asn] = country if country
          names[asn] = details['name'] if details['name']
        end
      end
    end.each(&:join)
    { countries: countries, names: names }
  end

  def self.block!(asn)
    rule = fetch_rule
    return unless rule

    current = blocked_asns(rule)
    return true if current.include?(asn.to_s)

    new_expression = "#{rule['expression']} or (ip.src.asnum eq #{asn})"
    conn.patch("/client/v4/zones/#{ENV['CLOUDFLARE_ZONE_ID']}/rulesets/#{ENV['CLOUDFLARE_RULESET_ID']}/rules/#{ENV['CLOUDFLARE_ASN_RULE_ID']}") do |req|
      req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
      req.headers['Content-Type'] = 'application/json'
      req.body = { expression: new_expression, action: rule['action'], description: rule['description'] }.to_json
    end
    true
  end

  def self.unblock!(asn)
    rule = fetch_rule
    return unless rule

    remaining = blocked_asns(rule) - [asn.to_s]
    return if remaining.empty?

    new_expression = remaining.map { |a| "(ip.src.asnum eq #{a})" }.join(' or ')
    conn.patch("/client/v4/zones/#{ENV['CLOUDFLARE_ZONE_ID']}/rulesets/#{ENV['CLOUDFLARE_RULESET_ID']}/rules/#{ENV['CLOUDFLARE_ASN_RULE_ID']}") do |req|
      req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
      req.headers['Content-Type'] = 'application/json'
      req.body = { expression: new_expression, action: rule['action'], description: rule['description'] }.to_json
    end
    true
  end

  def self.autoblock
    puts '[ASN autoblock] start'
    rule = nil
    rows = nil
    threads = [
      Thread.new { rule = fetch_rule },
      Thread.new { rows = fetch_analytics(hours: WINDOW_LENGTH) }
    ]
    threads.each(&:join)

    blocked = blocked_asns(rule)
    legit = legit_asns
    windows = suspicious_windows(rows: rows, hours: WINDOW_LENGTH, legit_asns: legit)
    candidates = windows.flat_map { |w| w[:asns].map { |r| r['asn'].to_s } }.uniq - blocked

    bot_pct = nil
    asn_countries = nil
    [
      Thread.new { bot_pct = fetch_bot_classifications(candidates) },
      Thread.new { asn_countries = fetch_asn_details(candidates)[:countries] }
    ].each(&:join)

    puts "[ASN autoblock] suspicious_windows=#{windows.size} candidate_asns=#{candidates.size} already_blocked=#{blocked.size}"
    puts "[ASN autoblock] candidates #{candidates.map { |a| "#{a} country=#{asn_countries[a] || 'unknown'}" }.join(', ')}"
    puts "[ASN autoblock] bot_classifications=#{bot_pct.size}"
    puts "[ASN autoblock] country_lookups=#{asn_countries.size}"
    to_block = bot_pct.select do |asn, v|
      v[:bot] > autoblock_bot_threshold(asn_countries[asn])
    end
    if to_block.empty?
      puts '[ASN autoblock] nothing to block (no candidate above bot threshold)'
      puts '[ASN autoblock] done'
      return
    end

    puts "[ASN autoblock] to_block=#{to_block.size} #{to_block.map { |asn, v| "#{asn}:#{v[:bot]}% country=#{asn_countries[asn] || 'unknown'}" }.join(', ')}"

    # Apply all blocks in a single API call
    new_expression = rule['expression']
    current = blocked_asns(rule)
    newly_blocked = []
    to_block.each do |asn, v|
      next if current.include?(asn.to_s)

      country = asn_countries[asn]
      threshold = autoblock_bot_threshold(country)
      new_expression = "#{new_expression} or (ip.src.asnum eq #{asn})"
      newly_blocked << [asn, v]
      puts "[ASN autoblock] blocked ASN #{asn} (#{v[:bot]}% bot, threshold #{threshold}%, #{country || 'country unknown'})"
    end

    if new_expression == rule['expression']
      puts '[ASN autoblock] rule unchanged (new ASNs already in rule)'
    else
      response = conn.patch("/client/v4/zones/#{ENV['CLOUDFLARE_ZONE_ID']}/rulesets/#{ENV['CLOUDFLARE_RULESET_ID']}/rules/#{ENV['CLOUDFLARE_ASN_RULE_ID']}") do |req|
        req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
        req.headers['Content-Type'] = 'application/json'
        req.body = { expression: new_expression, action: rule['action'], description: rule['description'] }.to_json
      end.body

      raise "failed to update Cloudflare rule: #{response.dig('errors')}" unless response['success']

      puts '[ASN autoblock] Cloudflare rule updated'
    end

    newly_blocked.each { |asn, v| notify_asn_blocked(asn, v) }
    puts '[ASN autoblock] done'
  rescue StandardError => e
    puts "[ASN autoblock] error: #{e.class}: #{e.message}"
    Honeybadger.notify(e)
  end

  def self.notify_asn_blocked(asn, v)
    EmailHelper.send_to_founder(
      subject: "[ASN blocked] #{asn} (#{v[:bot]}% bot)",
      body_text: [
        "ASN #{asn} was automatically blocked due to suspicious bot traffic.",
        "Review blocks at #{ENV['BASE_URI']}/stats/asns"
      ].join("\n")
    )
  end
end
