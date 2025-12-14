module OrganisationAccounting
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :update_paid_up
  end

  class_methods do
    def paid_up_fraction
      0.90
    end
  end

  def contribution_required
    !paid_up && (stripe_client_id || gocardless_instant_bank_pay)
  end

  def contribution_requested
    c = Money.new(0, 'GBP')
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

  def update_paid_up
    if contribution_not_required? || stripe_customer_id
      update_attributes(
        contribution_requested_gbp_cache: nil,
        contribution_paid_gbp_cache: nil,
        paid_up: true
      )
    else
      cr = contribution_requested
      cp = contribution_paid
      contribution_remaining = cr - cp
      update_attributes(
        contribution_requested_gbp_cache: cr.exchange_to('GBP').to_f,
        contribution_paid_gbp_cache: cp.exchange_to('GBP').to_f,
        paid_up: (contribution_remaining < Money.new(1 * 100, 'GBP')) || cp >= (Organisation.paid_up_fraction * cr)
      )
    end
  end

  def stripe_topup
    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = '2020-08-27'

    return unless stripe_customer_id && contribution_remaining > 0
    return if contribution_remaining < Money.new(1 * 100, 'GBP')

    # charge customer
    payment_method_id = Stripe::Customer.list_payment_methods(stripe_customer_id).first.id
    begin
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
    rescue StandardError => e
      Honeybadger.notify(e)
    end
  end

  def coinbase_confirmed_checkout_ids
    confirmed_checkout_ids = []
    client = CoinbaseCommerceClient::Client.new(api_key: coinbase_api_key)
    client.charge.auto_paging do |charge|
      confirmed_checkout_ids << charge['checkout']['id'] if charge['confirmed_at'] && charge['checkout'] && charge['checkout']['id']
    end
    confirmed_checkout_ids
  end
end
