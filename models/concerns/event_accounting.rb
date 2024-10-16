module EventAccounting
  extend ActiveSupport::Concern

  class_methods do
    def profit_share_roles
      %w[facilitator coordinator category_steward social_media]
    end
  end

  included do
    Event.profit_share_roles.each do |role|
      define_method "paid_to_#{role}" do
        s = rpayments.and(role: role).sum(&:amount_money)
        s == 0 ? Money.new(0, currency) : s
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
    if contribution_gbp_custom
      Money.new(contribution_gbp_custom * 100, 'GBP')
    elsif organisation && organisation.contribution_requested_per_event_gbp
      Money.new(organisation.contribution_requested_per_event_gbp * 100, 'GBP')
    else
      Money.new(Organisation.contribution_requested_per_event_gbp * 100, 'GBP')
    end
  end

  def contribution_gbp
    if organisation && organisation.fixed_fee
      cap
    else
      begin
        if ticket_types.empty?
          cap
        else
          five_percent_of_ticket_sales = Money.new(tickets.complete.sum(:discounted_price) * 0.05 * 100, currency).exchange_to('GBP')
          [cap, five_percent_of_ticket_sales].min
        end
      rescue StandardError
        cap
      end
    end
  end

  def stripe_revenue
    s = stripe_charges.sum(&:balance)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_fees
    s = stripe_charges.sum(&:fees)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_donations
    s = stripe_charges.sum(&:donations)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_ticket_revenue
    s = stripe_charges.sum(&:ticket_revenue)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_ticket_revenue_to_organisation
    s = stripe_charges.sum(&:ticket_revenue_to_organisation)
    s == 0 ? Money.new(0, currency) : s
  end

  def stripe_ticket_revenue_to_revenue_sharer
    s = stripe_charges.sum(&:ticket_revenue_to_revenue_sharer)
    s == 0 ? Money.new(0, currency) : s
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
    r = Money.new(0, currency)
    orders.each { |order| r += Money.new((order.credit_applied || 0) * 100, order.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def credit_on_behalf_of_organisation
    r = Money.new(0, currency)
    orders.each { |order| r += Money.new((order.credit_on_behalf_of_organisation || 0) * 100, order.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def credit_on_behalf_of_revenue_sharer
    r = Money.new(0, currency)
    orders.each { |order| r += Money.new((order.credit_on_behalf_of_revenue_sharer || 0) * 100, order.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def fixed_discounts_applied
    r = Money.new(0, currency)
    orders.each { |order| r += Money.new((order.fixed_discount_applied || 0) * 100, order.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def fixed_discounts_on_behalf_of_organisation
    r = Money.new(0, currency)
    orders.each { |order| r += Money.new((order.fixed_discount_on_behalf_of_organisation || 0) * 100, order.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def fixed_discounts_on_behalf_of_revenue_sharer
    r = Money.new(0, currency)
    orders.each { |order| r += Money.new((order.fixed_discount_on_behalf_of_revenue_sharer || 0) * 100, order.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.complete.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100, ticket.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def donation_revenue(skip_transferred: false)
    r = Money.new(0, currency)
    donations = skip_transferred ? self.donations.and(:transferred.ne => true) : self.donations
    donations.each { |donation| r += Money.new((donation.amount || 0) * 100, donation.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def organisation_discounted_ticket_revenue(skip_transferred: false)
    r = Money.new(0, currency)
    tickets = skip_transferred ? self.tickets.and(:transferred.ne => true) : self.tickets
    tickets.complete.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100 * (ticket.organisation_revenue_share || 1), ticket.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
  end

  def revenue_sharer_discounted_ticket_revenue(skip_transferred: false)
    r = Money.new(0, currency)
    tickets = skip_transferred ? self.tickets.and(:transferred.ne => true) : self.tickets
    tickets.complete.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100 * (1 - (ticket.organisation_revenue_share || 1)), ticket.currency) }
    r
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    Money.new(0, ENV['DEFAULT_CURRENCY'])
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
