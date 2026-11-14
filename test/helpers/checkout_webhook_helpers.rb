# Helpers the webhook, payment provider and order test files (test/integrations, test/payments, test/orders...) share:
# checkouts waiting for their webhook, and the webhooks that complete them
module CheckoutWebhookHelpers
  def create_incomplete_order(event, **attrs)
    price = attrs[:value] || event.ticket_types.first.price
    session_id = attrs[:session_id]
    order = Order.create!(
      {
        event: event,
        account: FactoryBot.create(:account),
        value: price,
        currency: event.currency,
        payment_completed: false
      }.merge(attrs)
    )
    ticket_attrs = {
      event: event,
      account: order.account,
      ticket_type: event.ticket_types.first,
      price: price
    }
    ticket_attrs[:session_id] = session_id if session_id
    order.tickets.create!(ticket_attrs)
    order
  end

  # The queued jobs that would email order's tickets, matched by the order's field the checkout knows it by (its
  # session_id, paypal_order_id) and the method each calls, as the records a job carries can mention send_tickets too
  def send_tickets_jobs(order, by:)
    queued_jobs(:send_tickets).select { |job| job.handler.include?("#{by}: #{order.send(by)}\n") }
  end

  # Posts body (JSON, or a hash to make it) to organisation's PayPal webhook
  def deliver_paypal_webhook(organisation, body)
    header 'Content-Type', 'application/json'
    post "/o/#{organisation.slug}/paypal_webhook", body.is_a?(String) ? body : body.to_json
  end

  # Posts payload to path as Stripe would, signed with secret, while env sets the ENV the endpoint reads its secret from
  def deliver_stripe_webhook(path, payload, secret:, env: {})
    with_env(env) do
      header 'Stripe-Signature', stripe_signature_header(payload, secret)
      header 'Content-Type', 'application/json'
      post path, payload
    end
  end

  # The Stripe-Signature header Stripe would send with payload, signed with secret
  def stripe_signature_header(payload, secret, timestamp: Time.now)
    Stripe::Webhook::Signature.generate_header(timestamp, Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret))
  end

  # The body of a Stripe webhook's event of type, about object
  def stripe_event_payload(type, object)
    { id: "evt_#{SecureRandom.hex(4)}", object: 'event', type: type, data: { object: object } }.to_json
  end

  # The body of a Stripe webhook's checkout.session.completed event (or another type) for session_id
  def checkout_completed_payload(session_id, type: 'checkout.session.completed', payment_status: 'paid')
    stripe_event_payload(type, { id: session_id, object: 'checkout.session', payment_status: payment_status })
  end
end
