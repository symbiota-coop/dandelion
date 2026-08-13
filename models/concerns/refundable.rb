module Refundable
  def refundable?
    payment_intent.present? || session_id.present? || gocardless_payment_id.present? || gocardless_payment_request_id.present?
  end

  # Re-fetch and persist a GoCardless payment id when it was lost (e.g. a broad
  # console `$unset` of gc* fields) but the payment request id remains.
  def ensure_gocardless_payment_id!
    return gocardless_payment_id if gocardless_payment_id.present?
    return if gocardless_payment_request_id.blank?

    payment_id = lookup_gocardless_payment_id_from_request
    return if payment_id.blank?

    if respond_to?(:persist_gocardless_payment_id)
      persist_gocardless_payment_id(payment_id)
    elsif respond_to?(:order) && order.respond_to?(:persist_gocardless_payment_id)
      order.persist_gocardless_payment_id(payment_id)
      reload if respond_to?(:reload)
    else
      set(gocardless_payment_id: payment_id)
    end
    gocardless_payment_id.presence || payment_id
  end

  def lookup_gocardless_payment_id_from_request
    token = event&.organisation&.gocardless_access_token
    return if token.blank?

    client = GoCardlessPro::Client.new(access_token: token)
    params = {
      resource_type: 'payments',
      action: 'confirmed'
    }
    if respond_to?(:created_at) && created_at
      params['created_at[gte]'] = (created_at - 1.day).iso8601
      params['created_at[lte]'] = (created_at + 30.days).iso8601
    end

    client.events.all(params: params).each do |gc_event|
      links = gc_event.to_h['links'] || {}
      next unless links['payment_request'] == gocardless_payment_request_id

      return links['payment'] if links['payment'].present?

      if links['billing_request'].present?
        billing_request = client.billing_requests.get(links['billing_request'])
        return billing_request.links.payment_request_payment if billing_request.links.payment_request_payment.present?
      end
    end
    nil
  rescue StandardError => e
    ErrorReporting.capture_exception(e)
    nil
  end

  def refund_via_stripe(payment_intent:, on_error:, amount: nil, refund_application_fee: false)
    Stripe.api_key = event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : event.organisation.stripe_sk
    Stripe.api_version = ENV['STRIPE_API_VERSION']
    pi = Stripe::PaymentIntent.retrieve payment_intent, { stripe_account: event.organisation.stripe_user_id }.compact

    if event.revenue_sharer_organisationship
      params = {
        charge: pi.charges.first.id,
        refund_application_fee: true,
        reverse_transfer: true
      }
      params[:amount] = (amount * 100).to_i if amount
      Stripe::Refund.create(params)
    elsif event.organisation.stripe_user_id
      params = { charge: pi.charges.first.id }
      params[:amount] = (amount * 100).to_i if amount
      params[:refund_application_fee] = true if refund_application_fee
      Stripe::Refund.create(params, { stripe_account: event.organisation.stripe_user_id })
    else
      params = { charge: pi.charges.first.id }
      params[:amount] = (amount * 100).to_i if amount
      Stripe::Refund.create(params)
    end
  rescue Stripe::InvalidRequestError => e
    on_error.call(e) if on_error
    true
  end

  def refund_via_gocardless(payment_id:, amount:, on_error:)
    return if payment_id.blank?

    client = GoCardlessPro::Client.new(access_token: event.organisation.gocardless_access_token)
    refund_amount = (amount * 100).to_i
    payment = client.payments.get(payment_id)

    client.refunds.create(
      params: {
        amount: refund_amount,
        total_amount_confirmation: payment.amount_refunded + refund_amount,
        links: {
          payment: payment_id
        }
      }
    )
  rescue StandardError => e
    on_error.call(e) if on_error
    true
  end
end
