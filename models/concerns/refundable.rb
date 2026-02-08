module Refundable
  def refundable?
    session_id || gocardless_payment_id
  end

  def refund_via_stripe(payment_intent:, on_error:, amount: nil, refund_application_fee: false)
    Stripe.api_key = event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : event.organisation.stripe_sk
    Stripe.api_version = '2020-08-27'
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
