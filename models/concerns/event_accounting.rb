module EventAccounting
  extend ActiveSupport::Concern

  class_methods do
    def profit_share_roles
      %w[organiser coordinator category_steward social_media]
    end
  end

  included do
    Event.profit_share_roles.each do |role|
      define_method "paid_to_#{role}" do
        instance_var = :"@paid_to_#{role}"
        instance_variable_get(instance_var) || instance_variable_set(instance_var, begin
          s = rpayments.and(role: role).sum(&:amount_money)
          s == 0 ? Money.new(0, currency) : s
        end)
      end
      define_method "remaining_to_#{role}" do
        send("profit_to_#{role}") - send("paid_to_#{role}")
      end
    end

    (Event.profit_share_roles + ['organisation']).each do |role|
      define_method "profit_to_#{role}" do
        revenue_share_to_organisation > 0 ? profit_less_donations * send("profit_share_to_#{role}") / revenue_share_to_organisation : Money.new(0, currency)
      end
    end
  end

  def remaining_sum
    s = Money.new(0, currency)
    Event.profit_share_roles.each do |role|
      s += send("remaining_to_#{role}")
    end
    s
  end

  def cap
    return unless cap_gbp

    Money.new(cap_gbp * 100, 'GBP')
  end

  def fixed_contribution
    return unless fixed_contribution_gbp

    Money.new(fixed_contribution_gbp * 100, 'GBP')
  end

  # promotion_fee_gbp is what an organisation paid in promotion fees for an event listed before they were scrapped
  def contribution_gbp
    if promotion_fee_gbp
      Money.new(promotion_fee_gbp * 100, 'GBP')
    elsif fixed_contribution
      fixed_contribution
    elsif cap
      percent_requested = 5
      percentage_of_ticket_sales = Money.new(tickets.complete.sum(:discounted_price) * (percent_requested.to_f / 100) * 100, currency).exchange_to('GBP')
      [cap, percentage_of_ticket_sales].min
    elsif organisation.try(:fixed_contribution_gbp)
      Money.new(organisation.fixed_contribution_gbp * 100, 'GBP')
    else
      percent_requested = organisation.try(:percent_requested) || 1
      Money.new(tickets.complete.sum(:discounted_price) * (percent_requested.to_f / 100) * 100, currency).exchange_to('GBP')
    end
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency => e
    # Crypto and community currencies have no exchange rate, so nothing is asked for their ticket sales
    ErrorReporting.capture_exception(e, context: { event_id: id.to_s, currency: currency }) if FIAT_CURRENCIES.include?(currency)
    Money.new(0, 'GBP')
  end

  def stripe_revenue
    @stripe_revenue ||= begin
      s = stripe_charges.sum(&:balance)
      s == 0 ? Money.new(0, currency) : s
    end
  end

  def stripe_fees
    @stripe_fees ||= begin
      s = stripe_charges.sum(&:fees)
      s == 0 ? Money.new(0, currency) : s
    end
  end

  def stripe_donations
    @stripe_donations ||= begin
      s = stripe_charges.sum(&:donations)
      s == 0 ? Money.new(0, currency) : s
    end
  end

  def stripe_ticket_revenue
    @stripe_ticket_revenue ||= begin
      s = stripe_charges.sum(&:ticket_revenue)
      s == 0 ? Money.new(0, currency) : s
    end
  end

  def stripe_ticket_revenue_to_organisation
    @stripe_ticket_revenue_to_organisation ||= begin
      s = stripe_charges.sum(&:ticket_revenue_to_organisation)
      s == 0 ? Money.new(0, currency) : s
    end
  end

  def stripe_ticket_revenue_to_revenue_sharer
    @stripe_ticket_revenue_to_revenue_sharer ||= begin
      s = stripe_charges.sum(&:ticket_revenue_to_revenue_sharer)
      s == 0 ? Money.new(0, currency) : s
    end
  end

  # This event's Stripe charges, found by the de_event_id in their metadata and fetched live from Stripe for the Stripe
  # report rather than stored, so refunds made in Stripe's dashboard show. Each charge and the totals are in the
  # currency the organisation's Stripe account settles in (a refund is converted at its charge's exchange rate)
  def stripe_report
    opts = StripeOpts.call(api_key: organisation.stripe_connect_json ? ENV['STRIPE_SK'] : organisation.stripe_sk, stripe_account: organisation.stripe_user_id)
    charges = []
    Stripe::Charge.search({ query: "metadata['de_event_id']:'#{id}'", limit: 100, expand: ['data.balance_transaction'] }, opts).auto_paging_each do |charge|
      balance_transaction = charge.balance_transaction
      next unless charge.status == 'succeeded' && balance_transaction.is_a?(Stripe::BalanceTransaction)

      currency = balance_transaction.currency.upcase
      # Application fees are donations to Dandelion, not Stripe's fees
      application_fee, fee = balance_transaction.fee_details.partition { |fee_detail| fee_detail.type == 'application_fee' }.map { |fee_details| fee_details.sum(&:amount) }
      # Refunding a whole order refunds its donation to Dandelion too. The charge doesn't say how much was refunded, so ask
      # for the application fee, which is Dandelion's, with Dandelion's own key
      if application_fee.positive? && charge.amount_refunded.positive? && charge.application_fee && organisation.stripe_connect_json
        application_fee_refunded = Stripe::ApplicationFee.retrieve(charge.application_fee, opts.except(:stripe_account)).amount_refunded
        application_fee -= (application_fee_refunded * (balance_transaction.exchange_rate || 1)).round
      end
      row = {
        payment_intent: charge.payment_intent,
        livemode: charge.livemode,
        created: Time.at(charge.created),
        name: charge.metadata['de_account_name'],
        email: charge.metadata['de_account_email'],
        order_id: charge.metadata['de_order_id'],
        disputed: charge.disputed,
        currency: currency,
        gross: Money.new(balance_transaction.amount, currency),
        refunded: Money.new((charge.amount_refunded * (balance_transaction.exchange_rate || 1)).round, currency),
        fees: Money.new(fee, currency),
        application_fees: Money.new(application_fee, currency)
      }
      # Revenue is what Dandelion counts as the event's revenue: what was paid, less refunds and the donations to Dandelion
      # it kept
      row[:revenue] = row[:gross] - row[:refunded] - row[:application_fees]
      row[:net] = row[:revenue] - row[:fees]
      charges << row
    end

    totals = charges.group_by { |charge| charge[:currency] }.map do |currency, currency_charges|
      sums = %i[gross refunded application_fees revenue fees net].to_h { |column| [column, currency_charges.sum(Money.new(0, currency)) { |charge| charge[column] }] }
      { currency: currency, charges: currency_charges.length, disputed: currency_charges.count { |charge| charge[:disputed] } }.merge(sums)
    end
    { charges: charges, totals: totals }
  end

  def stripe_profit
    stripe_revenue - stripe_fees + Money.new(stripe_revenue_adjustment * 100, currency)
  end

  def profit
    stripe_profit
  end

  def profit_less_donations
    stripe_profit - stripe_donations
  end

  def allocations_to_roles
    allocations = Money.new(0, currency)
    Event.profit_share_roles.each do |role|
      allocations += send("profit_to_#{role}")
    end
    allocations
  end

  def profit_less_donations_less_allocations
    profit_less_donations - allocations_to_roles
  end

  def profit_less_allocations
    profit_less_donations_less_allocations + stripe_donations
  end

  def profit_share_to_organisation
    revenue_share_to_organisation - Event.profit_share_roles.inject(0) { |sum, r| sum + (send("profit_share_to_#{r}") || 0) }
  end

  def credit_applied
    @credit_applied ||= begin
      r = Money.new(0, currency)
      orders.pluck(:credit_applied, :currency).each { |amount, order_currency| r += Money.new((amount || 0) * 100, order_currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end
  end

  def credit_on_behalf_of_organisation
    @credit_on_behalf_of_organisation ||= begin
      r = Money.new(0, currency)
      orders.each { |order| r += Money.new((order.credit_on_behalf_of_organisation || 0) * 100, order.currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end
  end

  def credit_on_behalf_of_revenue_sharer
    @credit_on_behalf_of_revenue_sharer ||= begin
      r = Money.new(0, currency)
      orders.each { |order| r += Money.new((order.credit_on_behalf_of_revenue_sharer || 0) * 100, order.currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end
  end

  def fixed_discounts_applied
    @fixed_discounts_applied ||= begin
      r = Money.new(0, currency)
      orders.pluck(:fixed_discount_applied, :currency).each { |amount, order_currency| r += Money.new((amount || 0) * 100, order_currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end
  end

  def fixed_discounts_on_behalf_of_organisation
    @fixed_discounts_on_behalf_of_organisation ||= begin
      r = Money.new(0, currency)
      orders.each { |order| r += Money.new((order.fixed_discount_on_behalf_of_organisation || 0) * 100, order.currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end
  end

  def fixed_discounts_on_behalf_of_revenue_sharer
    @fixed_discounts_on_behalf_of_revenue_sharer ||= begin
      r = Money.new(0, currency)
      orders.each { |order| r += Money.new((order.fixed_discount_on_behalf_of_revenue_sharer || 0) * 100, order.currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end
  end

  def discounted_ticket_revenue
    @discounted_ticket_revenue ||= begin
      r = Money.new(0, currency)
      tickets.complete.pluck(:discounted_price, :currency).each { |price, ticket_currency| r += Money.new((price || 0) * 100, ticket_currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end
  end

  def donation_revenue(skip_transferred: false)
    instance_var = skip_transferred ? :@donation_revenue_without_transferred : :@donation_revenue
    instance_variable_get(instance_var) || instance_variable_set(instance_var, begin
      r = Money.new(0, currency)
      donations = skip_transferred ? self.donations.and(transferred: false) : self.donations
      donations.pluck(:amount, :currency).each { |amount, donation_currency| r += Money.new((amount || 0) * 100, donation_currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end)
  end

  def donation_revenue_less_application_fees_paid_to_dandelion(skip_transferred: false)
    instance_var = skip_transferred ? :@donation_revenue_less_application_fees_without_transferred : :@donation_revenue_less_application_fees
    instance_variable_get(instance_var) || instance_variable_set(instance_var, begin
      r = Money.new(0, currency)
      donations = skip_transferred ? self.donations.and(transferred: false) : self.donations
      donations.and(application_fee_paid_to_dandelion: false).pluck(:amount, :currency).each { |amount, donation_currency| r += Money.new((amount || 0) * 100, donation_currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end)
  end

  def organisation_discounted_ticket_revenue(skip_transferred: false)
    instance_var = skip_transferred ? :@org_discounted_ticket_revenue_without_transferred : :@org_discounted_ticket_revenue
    instance_variable_get(instance_var) || instance_variable_set(instance_var, begin
      r = Money.new(0, currency)
      tickets = skip_transferred ? self.tickets.and(transferred: false) : self.tickets
      tickets.complete.pluck(:discounted_price, :organisation_revenue_share, :currency).each { |price, share, ticket_currency| r += Money.new((price || 0) * 100 * (share || 1), ticket_currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end)
  end

  def revenue_sharer_discounted_ticket_revenue(skip_transferred: false)
    instance_var = skip_transferred ? :@revenue_sharer_discounted_ticket_revenue_without_transferred : :@revenue_sharer_discounted_ticket_revenue
    instance_variable_get(instance_var) || instance_variable_set(instance_var, begin
      r = Money.new(0, currency)
      tickets = skip_transferred ? self.tickets.and(transferred: false) : self.tickets
      tickets.complete.pluck(:discounted_price, :organisation_revenue_share, :currency).each { |price, share, ticket_currency| r += Money.new((price || 0) * 100 * (1 - (share || 1)), ticket_currency) }
      r
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      Money.new(0, ENV['DEFAULT_CURRENCY'])
    end)
  end

  def revenue_share_to_organisation
    100 - (revenue_share_to_revenue_sharer || 0)
  end

  def organisation_revenue_share
    revenue_share_to_organisation / 100.0
  end

  def revenue
    organisation_discounted_ticket_revenue(skip_transferred: true) + donation_revenue(skip_transferred: true) - (credit_applied - credit_on_behalf_of_revenue_sharer) - (fixed_discounts_applied - fixed_discounts_on_behalf_of_revenue_sharer)
  end

  def ticket_revenue_to_organisation
    organisation_discounted_ticket_revenue(skip_transferred: true) - credit_on_behalf_of_organisation - fixed_discounts_on_behalf_of_organisation
  end

  def ticket_revenue_to_revenue_sharer
    revenue_sharer_discounted_ticket_revenue(skip_transferred: true) - credit_on_behalf_of_revenue_sharer - fixed_discounts_on_behalf_of_revenue_sharer
  end
end
