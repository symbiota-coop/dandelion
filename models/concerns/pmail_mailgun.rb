module PmailMailgun
  extend ActiveSupport::Concern

  def mailgun_url
    base_url = "https://#{organisation.mailgun_region == 'EU' ? 'app.eu.mailgun.com' : 'app.mailgun.com'}/mg/reporting/metrics"

    search_metrics = {
      dimensions: [],
      filter: {
        'AND' => [
          {
            attribute: 'tag',
            comparator: '=',
            values: [
              {
                label: id.to_s,
                value: id.to_s
              }
            ]
          }
        ]
      },
      includeSubaccounts: true,
      pagination: {
        limit: 10,
        skip: 0,
        sort: 'clicked_rate:desc'
      },
      metrics: %w[
        clicked_rate
        opened_rate
        delivered_rate
        unique_clicked_rate
        unique_opened_rate
      ],
      resolution: 'month'
    }

    start_date = sent_at
    end_date = Time.now

    date_range = {
      endDate: end_date.iso8601(3),
      startDate: start_date.iso8601(3)
    }

    # Build query parameters
    params = {
      'reporting-search-metrics' => search_metrics.to_json,
      'reporting-search-metrics-date-range' => date_range.to_json
    }

    "#{base_url}?#{params.to_query}"
  end

  def metrics
    mg_client = Mailgun::Client.new organisation.mailgun_api_key, (organisation.mailgun_region == 'EU' ? 'api.eu.mailgun.net' : 'api.mailgun.net')
    tags = Mailgun::Tags.new(mg_client)

    stats_data = tags.get_tag_stats(organisation.mailgun_domain, id, {
                                      event: %w[accepted delivered failed opened clicked unsubscribed complained stored],
                                      start: sent_at.to_i,
                                      resolution: 'month'
                                    })

    totals = {
      'accepted' => { 'incoming' => 0, 'outgoing' => 0, 'total' => 0 },
      'delivered' => { 'smtp' => 0, 'http' => 0, 'optimized' => 0, 'total' => 0 },
      'failed' => {
        'temporary' => { 'espblock' => 0, 'total' => 0 },
        'permanent' => {
          'suppress-bounce' => 0,
          'suppress-unsubscribe' => 0,
          'suppress-complaint' => 0,
          'bounce' => 0,
          'delayed-bounce' => 0,
          'webhook' => 0,
          'optimized' => 0,
          'total' => 0
        }
      },
      'stored' => { 'total' => 0 },
      'opened' => { 'total' => 0, 'unique' => 0 },
      'clicked' => { 'total' => 0, 'unique' => 0 },
      'unsubscribed' => { 'total' => 0 },
      'complained' => { 'total' => 0 }
    }

    stats_data['stats'].each do |month_stats|
      # Sum accepted stats
      totals['accepted']['incoming'] += month_stats['accepted']['incoming']
      totals['accepted']['outgoing'] += month_stats['accepted']['outgoing']
      totals['accepted']['total'] += month_stats['accepted']['total']

      # Sum delivered stats
      totals['delivered']['smtp'] += month_stats['delivered']['smtp']
      totals['delivered']['http'] += month_stats['delivered']['http']
      totals['delivered']['optimized'] += month_stats['delivered']['optimized']
      totals['delivered']['total'] += month_stats['delivered']['total']

      # Sum failed stats
      totals['failed']['temporary']['espblock'] += month_stats['failed']['temporary']['espblock']
      totals['failed']['temporary']['total'] += month_stats['failed']['temporary']['total']

      totals['failed']['permanent']['suppress-bounce'] += month_stats['failed']['permanent']['suppress-bounce']
      totals['failed']['permanent']['suppress-unsubscribe'] += month_stats['failed']['permanent']['suppress-unsubscribe']
      totals['failed']['permanent']['suppress-complaint'] += month_stats['failed']['permanent']['suppress-complaint']
      totals['failed']['permanent']['bounce'] += month_stats['failed']['permanent']['bounce']
      totals['failed']['permanent']['delayed-bounce'] += month_stats['failed']['permanent']['delayed-bounce']
      totals['failed']['permanent']['webhook'] += month_stats['failed']['permanent']['webhook']
      totals['failed']['permanent']['optimized'] += month_stats['failed']['permanent']['optimized']
      totals['failed']['permanent']['total'] += month_stats['failed']['permanent']['total']

      # Sum other stats
      totals['stored']['total'] += month_stats['stored']['total']
      totals['opened']['total'] += month_stats['opened']['total']
      totals['opened']['unique'] += month_stats['opened']['unique'] if month_stats['opened']['unique']
      totals['clicked']['total'] += month_stats['clicked']['total']
      totals['clicked']['unique'] += month_stats['clicked']['unique'] if month_stats['clicked']['unique']
      totals['unsubscribed']['total'] += month_stats['unsubscribed']['total']
      totals['complained']['total'] += month_stats['complained']['total']
    end

    # Calculate rates
    delivered_total = totals['delivered']['total']
    opened_total = totals['opened']['total']
    opened_unique = totals['opened']['unique']
    clicked_total = totals['clicked']['total']
    clicked_unique = totals['clicked']['unique']

    # Calculate sent_count = delivered + permanent_failures - suppressions
    permanent_failures = totals['failed']['permanent']['total']
    suppressions = totals['failed']['permanent']['suppress-bounce'] + totals['failed']['permanent']['suppress-unsubscribe'] + totals['failed']['permanent']['suppress-complaint']

    sent_count = delivered_total + permanent_failures - suppressions

    rates = {}
    if sent_count > 0
      rates['delivered_rate'] = (delivered_total.to_f / sent_count * 100).round(2)
      rates['opened_rate'] = (opened_total.to_f / delivered_total * 100).round(2)
      rates['unique_opened_rate'] = (opened_unique.to_f / delivered_total * 100).round(2)
      rates['clicked_rate'] = (clicked_total.to_f / delivered_total * 100).round(2)
      rates['unique_clicked_rate'] = (clicked_unique.to_f / delivered_total * 100).round(2)
    else
      rates['delivered_rate'] = 0.0
      rates['opened_rate'] = 0.0
      rates['unique_opened_rate'] = 0.0
      rates['clicked_rate'] = 0.0
      rates['unique_clicked_rate'] = 0.0
    end

    totals.merge('rates' => rates)
  end
end
