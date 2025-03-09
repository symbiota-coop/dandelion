module MonthlyContributionsCalculator
  def self.calculate
    d = [Date.new(24.months.ago.year, 24.months.ago.month, 1)]
    d << (d.last + 1.month) while d.last < Date.new(Date.today.year, Date.today.month, 1)

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = '2020-08-27'

    fragment = Fragment.find_or_create_by(key: 'monthly_contributions')

    # Process one month at a time
    monthly_data = d.map do |x|
      start_of_month = x
      end_of_month = x + 1.month
      start_timestamp = start_of_month.to_time.to_i
      end_timestamp = end_of_month.to_time.to_i

      monthly_contributions = Money.new(0, 'GBP')

      # Process charges for this month only
      charges_for_month = Stripe::Charge.list({
                                                created: { gte: start_timestamp, lt: end_timestamp },
                                                limit: 100
                                              })

      charges_for_month.auto_paging_each do |c|
        next unless c.status == 'succeeded'
        next if c.refunded
        next if ENV['STRIPE_PAYMENT_INTENTS_TO_IGNORE'] && c.payment_intent.in?(ENV['STRIPE_PAYMENT_INTENTS_TO_IGNORE'].split(','))

        monthly_contributions += Money.new(c['amount'], c['currency'])
      end

      # Process application fees for this month only
      fees_for_month = Stripe::ApplicationFee.list({
                                                     created: { gte: start_timestamp, lt: end_timestamp },
                                                     limit: 100
                                                   })

      fees_for_month.auto_paging_each do |f|
        next if f.refunded

        monthly_contributions += Money.new(f['amount'], f['currency'])
      end

      monthly_contributions = monthly_contributions.exchange_to('GBP')
      ["#{Date::MONTHNAMES[x.month]} #{x.year}", monthly_contributions.to_i]
    end

    fragment.update_attributes expires: 1.day.from_now, value: monthly_data.to_json
  end
end
