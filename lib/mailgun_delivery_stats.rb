module MailgunDeliveryStats
  METRICS = %w[
    delivered_count failed_count permanent_failed_count temporary_failed_count
    bounced_count hard_bounces_count soft_bounces_count complained_count
    delivered_rate bounce_rate permanent_fail_rate
  ].freeze

  MIN_DELIVERIES = 10
  ALERT_THRESHOLD = 0.99
  ALERT_PERIOD = 24

  class << self
    def fetch(period: '24')
      api_key = ENV['MAILGUN_API_KEY']
      api_host = ENV['MAILGUN_REGION']
      domain = ENV['MAILGUN_TICKETS_HOST'].presence

      return { error: 'MAILGUN_API_KEY is not set' } if api_key.blank?
      return { error: 'MAILGUN_TICKETS_HOST is not set' } if domain.blank?
      return { error: 'MAILGUN_REGION is not set' } if api_host.blank?

      duration = case period.to_s
                 when '24' then '24h'
                 when '7' then '7d'
                 when '90' then '90d'
                 else '30d'
                 end

      client = Mailgun::Client.new(api_key, api_host, 'v1')
      metrics = Mailgun::Metrics.new(client)
      end_time = Time.now.utc

      filter = {
        AND: [{ attribute: 'domain', comparator: '=', values: [{ label: domain, value: domain }] }]
      }

      base = {
        end: end_time.rfc2822,
        duration: duration,
        resolution: 'day',
        include_aggregates: false,
        filter: filter,
        metrics: METRICS
      }

      provider = metrics.account_metrics(base.merge(
                                           dimensions: ['recipient_provider'],
                                           pagination: { limit: 500, skip: 0, sort: 'delivered_count:desc' }
                                         ))

      { by_provider: filter_min_deliveries(provider_rows(provider['items'])) }
    rescue Mailgun::CommunicationError => e
      body = e.respond_to?(:response) && e.response ? e.response.body.to_s : ''
      msg = [e.message, body].reject(&:blank?).join(' — ')
      { error: msg.length > 800 ? "#{msg[0..800]}…" : msg }
    rescue StandardError => e
      { error: e.message }
    end

    def format_pct(rate_f)
      rate_f.nil? ? '—' : "#{format('%0.2f', rate_f * 100)}%"
    end

    def check_and_notify
      result = fetch(period: ALERT_PERIOD)

      if result[:error]
        notify_error(result[:error])
        return
      end

      rows = result[:by_provider] || []
      low = rows.select { |r| r[:delivered_rate_f].present? && r[:delivered_rate_f] < ALERT_THRESHOLD }
      return if low.empty?

      notify_low_delivery(low)
    end

    private

    def provider_rows(items)
      (items || []).map do |item|
        dim = item['dimensions']&.find { |d| d['dimension'] == 'recipient_provider' }
        label = dim&.dig('display_value').to_s.strip.presence || dim&.dig('value').to_s.strip.presence
        label = '(unknown provider)' if label.blank?
        m = item['metrics'] || {}
        delivered_count = m['delivered_count'].to_i
        bounced_count = m['bounced_count'].to_i
        bounce_rate_f = parse_rate(m['bounce_rate'])
        bounce_rate_f = fallback_bounce_rate_f(delivered_count, bounced_count) if bounce_rate_f.nil? || (bounce_rate_f.zero? && bounced_count.positive?)

        {
          label: label,
          delivered_count: delivered_count,
          failed_count: m['failed_count'].to_i,
          permanent_failed_count: m['permanent_failed_count'].to_i,
          bounced_count: bounced_count,
          complained_count: m['complained_count'].to_i,
          delivered_rate_f: parse_rate(m['delivered_rate']),
          bounce_rate_f: bounce_rate_f
        }
      end
    end

    def filter_min_deliveries(rows)
      rows.select { |r| r[:delivered_count] >= MIN_DELIVERIES }
    end

    def parse_rate(s)
      return nil if s.nil? || s.to_s.strip.empty?

      v = s.to_f
      v > 1 ? v / 100.0 : v
    end

    def fallback_bounce_rate_f(delivered_count, bounced_count)
      return nil unless bounced_count.positive?

      denom = delivered_count + bounced_count
      return nil unless denom.positive?

      bounced_count.to_f / denom
    end

    def notify_error(message)
      send_to_admins(
        subject: '[Mailgun] Delivery stats unavailable',
        body: "Could not load Mailgun analytics for #{ENV['MAILGUN_TICKETS_HOST']} (last #{ALERT_PERIOD}h):\n\n#{message}"
      )
    end

    def notify_low_delivery(rows)
      domain = ENV['MAILGUN_TICKETS_HOST']
      lines = rows.map do |r|
        "- #{r[:label]}: #{format_pct(r[:delivered_rate_f])} (#{r[:delivered_count]} delivered)"
      end
      body = <<~TEXT.strip
        Mailgun delivered rate is below #{(ALERT_THRESHOLD * 100).to_i}% for at least one recipient provider (domain #{domain}, last #{ALERT_PERIOD}h):

        #{lines.join("\n")}

        Stats: #{ENV['BASE_URI']}/stats/delivery
      TEXT

      send_to_admins(
        subject: '[Mailgun] Low delivery rate by ESP',
        body: body
      )
    end

    def send_to_admins(subject:, body:)
      unless ENV['MAILGUN_API_KEY'].present? && ENV['MAILGUN_REGION'].present? && ENV['MAILGUN_NOTIFICATIONS_HOST'].present?
        puts 'MailgunDeliveryStats: skipped (set MAILGUN_API_KEY, MAILGUN_REGION, MAILGUN_NOTIFICATIONS_HOST to email admins)'
        return
      end

      mg_client = Mailgun::Client.new(ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION'])
      batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

      batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
      batch_message.subject subject
      batch_message.body_text body

      Account.and(admin: true).each do |account|
        batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
      end

      batch_message.finalize if Padrino.env == :production
    end
  end
end
