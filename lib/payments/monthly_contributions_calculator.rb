module MonthlyContributionsCalculator
  BREAKDOWN_KEYS = %w[direct_stripe_charges stripe_connect_application_fees].freeze
  BREAKDOWN_LABELS = {
    'direct_stripe_charges' => 'Direct Stripe charges',
    'stripe_connect_application_fees' => 'Stripe Connect application fees'
  }.freeze
  # CSS colours, resolved in the browser by cssColor
  BREAKDOWN_COLORS = {
    'direct_stripe_charges' => 'var(--theme-500)',
    'stripe_connect_application_fees' => 'var(--theme-400)'
  }.freeze

  def self.calculate
    d = generate_month_range
    fragment = Fragment.find_or_create_by(key: 'monthly_contributions')

    monthly_data = d.map { |month| calculate_month_data(month) }
    fragment.update_attributes expires: 2.days.from_now, value: monthly_data.to_json
  end

  # Today in UTC, as months run in UTC (calculate_month_data)
  def self.today
    Time.now.utc.to_date
  end

  def self.update_current_month
    current_month = Date.new(today.year, today.month, 1)
    fragment = Fragment.find_by(key: 'monthly_contributions')
    return unless fragment

    existing_data = JSON.parse(fragment.value || '[]')
    current_month_data = calculate_month_data(current_month)

    update_month_in_data(existing_data, current_month_data)
    fragment.update_attributes value: existing_data.to_json
  end

  def self.generate_month_range
    d = [Date.new(today.year, today.month, 1) << 24]
    d << (d.last + 1.month) while d.last < Date.new(today.year, today.month, 1)
    d
  end

  def self.calculate_month_data(month)
    # Months run midnight to midnight UTC, as Stripe's own reports and our other Stripe queries (StripeCharge,
    # StripeTransaction) do, whatever the server's or the app's time zone
    next_month = month + 1.month
    start_timestamp = Time.utc(month.year, month.month, 1).to_i
    end_timestamp = Time.utc(next_month.year, next_month.month, 1).to_i

    charges_contrib, charges_stripe_fees = process_charges(start_timestamp, end_timestamp)
    fees_contrib, fees_stripe_fees = process_fees(start_timestamp, end_timestamp)

    breakdown = {
      'direct_stripe_charges' => (charges_contrib - charges_stripe_fees).exchange_to('GBP'),
      'stripe_connect_application_fees' => (fees_contrib - fees_stripe_fees).exchange_to('GBP')
    }

    # Each part is cut to whole pounds and the total is their sum, so the breakdown always adds up to the total
    breakdown = breakdown.transform_values(&:to_i)

    [
      "#{Date::MONTHNAMES[month.month]} #{month.year}",
      breakdown.values.sum,
      breakdown
    ]
  end

  def self.process_charges(start_timestamp, end_timestamp)
    contributions = Money.new(0, 'GBP')
    stripe_fees = Money.new(0, 'GBP')

    charges = Stripe::Charge.list({
                                    created: { gte: start_timestamp, lt: end_timestamp },
                                    limit: 100,
                                    expand: ['data.balance_transaction']
                                  }, StripeOpts.call)

    charges.auto_paging_each do |c|
      next unless c.status == 'succeeded'
      next if c.refunded
      next if ENV['STRIPE_PAYMENT_INTENTS_TO_IGNORE'] && c.payment_intent.in?(ENV['STRIPE_PAYMENT_INTENTS_TO_IGNORE'].split(','))

      # A partial refund counts what was kept. Stripe keeps its fee on a refund, so the fee is still taken off
      contributions += Money.new(c['amount'] - c['amount_refunded'].to_i, c['currency'])
      if c.balance_transaction && c.balance_transaction['fee']
        bt = c.balance_transaction
        stripe_fees += Money.new(bt['fee'], bt['currency'] || 'usd')
      end
    end

    [contributions, stripe_fees]
  end

  def self.process_fees(start_timestamp, end_timestamp)
    contributions = Money.new(0, 'GBP')
    stripe_fees = Money.new(0, 'GBP')

    fees = Stripe::ApplicationFee.list({
                                         created: { gte: start_timestamp, lt: end_timestamp },
                                         limit: 100,
                                         expand: ['data.balance_transaction']
                                       }, StripeOpts.call)

    fees.auto_paging_each do |f|
      next if f.refunded

      # A partially refunded application fee counts what was kept; its balance transaction's fee is still taken off
      contributions += Money.new(f['amount'] - f['amount_refunded'].to_i, f['currency'])
      if f.balance_transaction && f.balance_transaction['fee']
        bt = f.balance_transaction
        stripe_fees += Money.new(bt['fee'], bt['currency'] || 'usd')
      end
    end

    [contributions, stripe_fees]
  end

  def self.update_month_in_data(existing_data, current_month_data)
    current_month_label = current_month_data[0]
    updated = false

    existing_data.map! do |entry|
      if entry[0] == current_month_label
        updated = true
        current_month_data
      else
        entry
      end
    end

    existing_data << current_month_data unless updated
  end

  def self.contribution_data(currency = nil)
    currency ||= ENV['DEFAULT_CURRENCY'] || 'GBP'
    fragment = Fragment.find_by(key: 'monthly_contributions')

    return nil unless fragment&.value

    monthly_data = JSON.parse(fragment.value)
    current_month = "#{Date::MONTHNAMES[today.month]} #{today.year}"
    current_month_data = monthly_data.find { |d| d[0] == current_month }

    return nil unless current_month_data

    monthly_contributions = Money.new(current_month_data[1] * 100, 'GBP')
    monthly_contributions = monthly_contributions.exchange_to(currency)

    return nil unless monthly_contributions > 0

    current_month_value = monthly_contributions.to_i
    days_in_month = Date.new(today.year, today.month, -1).day
    days_passed = today.day
    projected_value = (current_month_value.to_f / days_passed * days_in_month).round

    {
      current: monthly_contributions,
      projected: projected_value,
      currency: currency
    }
  end
end
