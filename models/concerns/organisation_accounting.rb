module OrganisationAccounting
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :update_paid_up
  end

  def paid_up_fraction_or_default
    paid_up_fraction || 0.90
  end

  def contribution_reminder
    return false if contribution_not_required

    !paid_up && (stripe_client_id || gocardless_instant_bank_pay || oc_slug)
  end

  def contribution_requested(exclude_promotion_fees: false)
    c = Money.new(0, 'GBP')
    contributable_events.each do |event|
      c += event.contribution_gbp(exclude_promotion_fee: exclude_promotion_fees)
    end
    c.exchange_to(FIAT_CURRENCIES.include?(currency) ? currency : ENV['DEFAULT_CURRENCY'])
  end

  def auto_topup_contribution_requested
    contribution_requested(exclude_promotion_fees: true)
  end

  def contribution_paid
    s = Money.new(0, 'GBP')
    organisation_contributions.and(payment_completed: true).each do |organisation_contribution|
      s += Money.new(organisation_contribution.amount * 100, organisation_contribution.currency)
    end
    s.exchange_to(FIAT_CURRENCIES.include?(currency) ? currency : ENV['DEFAULT_CURRENCY'])
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
      update_attributes(
        contribution_requested_gbp_cache: cr.exchange_to('GBP').to_f,
        contribution_paid_gbp_cache: cp.exchange_to('GBP').to_f,
        paid_up: paid_up_by_contribution?(cr: cr, cp: cp)
      )
    end
  end

  def paid_up_by_contribution?(cr: contribution_requested, cp: contribution_paid,
                               paid_up_tolerance: Money.new(1 * 100, 'GBP'))
    contribution_remaining = cr - cp
    contribution_remaining <= Money.new(100 * 100, 'GBP') &&
      ((contribution_remaining < paid_up_tolerance) ||
        cp >= (paid_up_fraction_or_default * cr))
  end

  def stripe_topup
    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = ENV['STRIPE_API_VERSION']

    return unless stripe_customer_id

    # Promotion-fee events still appear in contribution totals, but we do not auto-charge them
    cr = auto_topup_contribution_requested
    cp = contribution_paid
    return if paid_up_by_contribution?(cr: cr, cp: cp)

    contribution_remaining = cr - cp
    return unless contribution_remaining > 0
    return if contribution_remaining < Money.new(1 * 100, 'GBP')

    # charge customer
    payment_method_id = Stripe::Customer.list_payment_methods(stripe_customer_id).first.id
    begin
      pi = Stripe::PaymentIntent.create({
                                          amount: contribution_remaining.cents,
                                          currency: contribution_remaining.currency,
                                          customer: stripe_customer_id,
                                          payment_method: payment_method_id,
                                          automatic_payment_methods: { enabled: true, allow_redirects: 'never' },
                                          off_session: true,
                                          confirm: true
                                        })
      organisation_contribution = organisation_contributions.create amount: contribution_remaining.cents.to_f / 100, currency: contribution_remaining.currency, payment_intent: pi.id, payment_completed: true
      organisation_contribution.send_notification
    rescue Stripe::CardError => e
      send_insufficient_funds_topup_notification if e.message.to_s.downcase.include?('insufficient funds')
      Honeybadger.notify(e, context: { organisation_slug: slug })
    rescue StandardError => e
      Honeybadger.notify(e, context: { organisation_slug: slug })
    end
  end

  def send_insufficient_funds_topup_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "#{name}: top-up failed due to insufficient funds"
    batch_message.body_html EmailHelper.html(:insufficient_funds_topup, organisation: self)

    admins.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
  handle_asynchronously :send_insufficient_funds_topup_notification
end
