# Helpers the webhook, payment provider and order test files (test/integrations, test/payments, test/orders) share:
# checkouts waiting for their webhook
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
    Delayed::Job.all.select do |job|
      job.handler.match?(/^method_name: :send_tickets(_without_delay)?$/) && job.handler.include?("#{by}: #{order.send(by)}\n")
    end
  end

  # Posts body (JSON, or a hash to make it) to organisation's PayPal webhook
  def deliver_paypal_webhook(organisation, body)
    header 'Content-Type', 'application/json'
    post "/o/#{organisation.slug}/paypal_webhook", body.is_a?(String) ? body : body.to_json
  end
end
