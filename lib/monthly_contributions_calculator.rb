module MonthlyContributionsCalculator
  def self.calculate
    setup_stripe

    d = generate_month_range
    fragment = Fragment.find_or_create_by(key: 'monthly_contributions')

    monthly_data = d.map { |month| calculate_month_data(month) }
    fragment.update_attributes expires: 1.day.from_now, value: monthly_data.to_json
  end

  def self.update_current_month
    setup_stripe

    current_month = Date.new(Date.today.year, Date.today.month, 1)
    fragment = Fragment.find_by(key: 'monthly_contributions')
    return unless fragment

    existing_data = JSON.parse(fragment.value || '[]')
    current_month_data = calculate_month_data(current_month)

    update_month_in_data(existing_data, current_month_data)
    fragment.update_attributes value: existing_data.to_json
  end

  def self.setup_stripe
    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = '2020-08-27'
  end

  def self.generate_month_range
    d = [Date.new(24.months.ago.year, 24.months.ago.month, 1)]
    d << (d.last + 1.month) while d.last < Date.new(Date.today.year, Date.today.month, 1)
    d
  end

  def self.calculate_month_data(month)
    start_timestamp = month.to_time.to_i
    end_timestamp = (month + 1.month).to_time.to_i

    monthly_contributions = process_charges(start_timestamp, end_timestamp)
    monthly_contributions += process_fees(start_timestamp, end_timestamp)
    monthly_contributions = monthly_contributions.exchange_to('GBP')

    ["#{Date::MONTHNAMES[month.month]} #{month.year}", monthly_contributions.to_i]
  end

  def self.process_charges(start_timestamp, end_timestamp)
    contributions = Money.new(0, 'GBP')

    charges = Stripe::Charge.list({
                                    created: { gte: start_timestamp, lt: end_timestamp },
                                    limit: 100
                                  })

    charges.auto_paging_each do |c|
      next unless c.status == 'succeeded'
      next if c.refunded
      next if ENV['STRIPE_PAYMENT_INTENTS_TO_IGNORE'] && c.payment_intent.in?(ENV['STRIPE_PAYMENT_INTENTS_TO_IGNORE'].split(','))

      contributions += Money.new(c['amount'], c['currency'])
    end

    contributions
  end

  def self.process_fees(start_timestamp, end_timestamp)
    contributions = Money.new(0, 'GBP')

    fees = Stripe::ApplicationFee.list({
                                         created: { gte: start_timestamp, lt: end_timestamp },
                                         limit: 100
                                       })

    fees.auto_paging_each do |f|
      next if f.refunded

      contributions += Money.new(f['amount'], f['currency'])
    end

    contributions
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
    current_month = "#{Date::MONTHNAMES[Date.today.month]} #{Date.today.year}"
    current_month_data = monthly_data.find { |d| d[0] == current_month }

    return nil unless current_month_data

    monthly_contributions = Money.new(current_month_data[1] * 100, 'GBP')
    monthly_contributions = monthly_contributions.exchange_to(currency)

    return nil unless monthly_contributions > 0

    current_month_value = monthly_contributions.to_i
    days_in_month = Date.new(Date.today.year, Date.today.month, -1).day
    days_passed = Date.today.day
    projected_value = (current_month_value.to_f / days_passed * days_in_month).round

    {
      current: monthly_contributions,
      projected: projected_value,
      currency: currency
    }
  end
end
