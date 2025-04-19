module OrderAccounting
  extend ActiveSupport::Concern

  def ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.price || 0) * 100, ticket.currency) }
    r
  end

  def discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100, ticket.currency) }
    r
  end

  def organisation_discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100 * (ticket.organisation_revenue_share || 1), ticket.currency) }
    r
  end

  def revenue_sharer_discounted_ticket_revenue
    r = Money.new(0, currency)
    tickets.each { |ticket| r += Money.new((ticket.discounted_price || 0) * 100 * (1 - (ticket.organisation_revenue_share || 1)), ticket.currency) }
    r
  end

  def donation_revenue
    r = Money.new(0, currency)
    donations.each { |donation| r += Money.new((donation.amount || 0) * 100, donation.currency) }
    r
  end

  def donation_revenue_less_application_fees_paid_to_dandelion
    r = Money.new(0, currency)
    donations.and(:application_fee_paid_to_dandelion.ne => true).each { |donation| r += Money.new((donation.amount || 0) * 100, donation.currency) }
    r
  end

  def total
    ((discounted_ticket_revenue + donation_revenue).cents.to_f / 100) - (credit_applied || 0) - (fixed_discount_applied || 0)
  end

  def calculate_application_fee_amount
    (((discounted_ticket_revenue.cents * organisation_revenue_share) + donation_revenue.cents).to_f / 100) - (credit_on_behalf_of_organisation || 0) - (fixed_discount_on_behalf_of_organisation || 0)
  end

  def credit_on_behalf_of_organisation
    credit_applied - credit_on_behalf_of_revenue_sharer if revenue_sharer && credit_on_behalf_of_revenue_sharer && credit_applied && credit_applied.positive?
  end

  def credit_on_behalf_of_revenue_sharer
    o.credit_applied * ((o.discounted_ticket_revenue / (o.discounted_ticket_revenue + o.donation_revenue)) * (1 - o.organisation_revenue_share)).to_f if revenue_sharer && credit_applied && credit_applied.positive? && (discounted_ticket_revenue + donation_revenue).positive?
  end

  def fixed_discount_on_behalf_of_organisation
    fixed_discount_applied - fixed_discount_on_behalf_of_revenue_sharer if revenue_sharer && fixed_discount_applied && fixed_discount_applied.positive?
  end

  def fixed_discount_on_behalf_of_revenue_sharer
    fixed_discount_applied * ((discounted_ticket_revenue / (discounted_ticket_revenue + donation_revenue)) * (1 - organisation_revenue_share)).to_f if revenue_sharer && fixed_discount_applied && fixed_discount_applied.positive? && (discounted_ticket_revenue + donation_revenue).positive?
  end
end
