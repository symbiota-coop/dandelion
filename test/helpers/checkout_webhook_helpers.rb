# Helpers the webhook and payment provider test files (test/integrations, test/payments) share: checkouts
# waiting for their webhook
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
end
