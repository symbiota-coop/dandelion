module OrganisationAccounting
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :update_paid_up
  end

  class_methods do
    def contribution_requested_per_event_gbp
      20
    end

    def paid_up_fraction
      0.8
    end
  end

  def contribution_requested
    c = Money.new((-1 * (contribution_offset_gbp || 0) * 100) || 0, 'GBP')
    contributable_events.each do |event|
      c += event.contribution_gbp
    end
    c.exchange_to(MAJOR_CURRENCIES.include?(currency) ? currency : ENV['DEFAULT_CURRENCY'])
  end

  def contribution_paid
    s = Money.new(0, 'GBP')
    organisation_contributions.and(payment_completed: true).each do |organisation_contribution|
      s += Money.new(organisation_contribution.amount * 100, organisation_contribution.currency)
    end
    s.exchange_to(MAJOR_CURRENCIES.include?(currency) ? currency : ENV['DEFAULT_CURRENCY'])
  end

  def fraction_paid
    cr = Money.new(contribution_requested_gbp_cache * 100, 'GBP') if contribution_requested_gbp_cache
    cp = Money.new(contribution_paid_gbp_cache * 100, 'GBP') if contribution_paid_gbp_cache
    return unless cr && cr > 0 && cp && cp > 0

    cp / cr
  end

  def contribution_remaining
    contribution_requested - contribution_paid
  end

  def contribution_threshold
    Money.new((contribution_requested_per_event_gbp || Organisation.contribution_requested_per_event_gbp) * 100, 'GBP')
  end

  def update_paid_up
    cr = contribution_requested
    cp = contribution_paid
    update_attribute(:contribution_requested_gbp_cache, cr.exchange_to('GBP').to_f)
    update_attribute(:contribution_paid_gbp_cache, cp.exchange_to('GBP').to_f)
    update_attribute(:paid_up, nil)
    begin
      update_attribute(:paid_up, contribution_not_required? || !stripe_customer_id.nil? || cr < contribution_threshold || contributable_events.count == 1 || cp >= (Organisation.paid_up_fraction * cr))
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      update_attribute(:paid_up, true)
    end
  end

  def stripe_topup
    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = '2020-08-27'

    return unless stripe_customer_id && contribution_remaining > 0

    # charge customer
    payment_method_id = Stripe::Customer.list_payment_methods(stripe_customer_id).first.id
    pi = Stripe::PaymentIntent.create({
                                        amount: contribution_remaining.cents,
                                        currency: contribution_remaining.currency,
                                        customer: stripe_customer_id,
                                        payment_method: payment_method_id,
                                        off_session: true,
                                        confirm: true
                                      })
    organisation_contribution = organisation_contributions.create amount: contribution_remaining.cents.to_f / 100, currency: contribution_remaining.currency, payment_intent: pi.id, payment_completed: true
    organisation_contribution.send_notification
  end
end
