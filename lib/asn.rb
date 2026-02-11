module Asn
  BASELINE_ASN = 2856
  WINDOW_LENGTH = 6
  THRESHOLD = 1

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

  def self.fetch_analytics(days:)
    since = (Time.now.utc - (days * 86_400)).strftime('%Y-%m-%dT%H:%M:%SZ')
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

  def self.fetch_country_data(days:)
    since = (Time.now.utc - (days * 86_400)).strftime('%Y-%m-%dT%H:%M:%SZ')
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

  def self.suspicious_windows(rows:, days:, legit_asns:)
    windows = []
    last_baseline_count = 0
    tz = TZInfo::Timezone.get('Europe/Stockholm')
    now = tz.to_local(Time.now.utc)
    window_start = tz.local_time(now.year, now.month, now.day, (now.hour / WINDOW_LENGTH) * WINDOW_LENGTH) - (days * 86_400)
    while window_start < now
      window_end = window_start + (WINDOW_LENGTH * 3600)

      window_rows = rows.select do |r|
        t = Time.parse(r.dig('dimensions', 'datetimeHour'))
        t >= window_start && t < window_end
      end

      by_asn = window_rows.group_by { |r| r.dig('dimensions', 'clientAsn') }.map do |asn, rs|
        { 'asn' => asn, 'description' => rs.first.dig('dimensions', 'clientASNDescription'), 'count' => rs.sum { |r| r['count'] } }
      end
      baseline_count = by_asn.find { |r| r['asn'].to_s == BASELINE_ASN.to_s }&.dig('count') || 0
      baseline_count = last_baseline_count if window_start.hour == 0
      last_baseline_count = baseline_count
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
        resp = c.get("/client/v4/radar/http/summary/bot_class?asn=#{asn}&dateRange=7d&format=json") do |req|
          req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
        end.body
        if resp['success']
          summary = resp.dig('result', 'summary_0') || {}
          bot = summary['bot']&.to_f
          human = summary['human']&.to_f
          mutex.synchronize { bot_pct[asn] = { bot: bot&.round(1), human: human&.round(1) } } if bot && human
        end
      rescue StandardError
        nil
      end
    end.each(&:join)
    bot_pct
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
    days = 1

    rule = nil
    rows = nil
    threads = [
      Thread.new { rule = fetch_rule },
      Thread.new { rows = fetch_analytics(days: days) }
    ]
    threads.each(&:join)

    blocked = blocked_asns(rule)
    legit = legit_asns
    windows = suspicious_windows(rows: rows, days: days, legit_asns: legit)
    candidates = windows.flat_map { |w| w[:asns].map { |r| r['asn'].to_s } }.uniq - blocked

    bot_pct = fetch_bot_classifications(candidates)
    to_block = bot_pct.select { |_, v| v[:bot] > 50 }
    return if to_block.empty?

    # Apply all blocks in a single API call
    new_expression = rule['expression']
    current = blocked_asns(rule)
    to_block.each do |asn, v|
      next if current.include?(asn.to_s)

      new_expression = "#{new_expression} or (ip.src.asnum eq #{asn})"
      puts "blocked ASN #{asn} (#{v[:bot]}% bot)"
    end

    if new_expression != rule['expression']
      conn.patch("/client/v4/zones/#{ENV['CLOUDFLARE_ZONE_ID']}/rulesets/#{ENV['CLOUDFLARE_RULESET_ID']}/rules/#{ENV['CLOUDFLARE_ASN_RULE_ID']}") do |req|
        req.headers['Authorization'] = "Bearer #{ENV['CLOUDFLARE_API_KEY']}"
        req.headers['Content-Type'] = 'application/json'
        req.body = { expression: new_expression, action: rule['action'], description: rule['description'] }.to_json
      end
    end

    to_block.each { |asn, v| notify_asn_blocked(asn, v) }
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
