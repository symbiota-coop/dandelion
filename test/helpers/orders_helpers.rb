# Helpers the order test files (test/orders, and the resales in test/bookings) share
module OrdersHelpers
  # Changes a ticketholder field on the order's page, which saves it when it changes, as fill_in blurs it
  def change_ticketholder_field(field, value)
    fill_in field, with: value
  end

  def create_complete_order
    create_event(prices: [0])
    @attendee = FactoryBot.create(:account)
    @order = @event.orders.create!(
      account: @attendee,
      currency: @event.currency,
      value: 0,
      payment_completed: true,
      original_description: 'Test order'
    )
  end

  def create_paid_order(event)
    Order.create!(
      event: event,
      account: FactoryBot.create(:account),
      value: 10,
      payment_completed: true,
      payment_intent: "pi_#{SecureRandom.hex(8)}",
      currency: event.currency
    )
  end

  # Stubs Stripe for refunds of a £10 order, its charge
  def with_stubbed_stripe_refunds
    refunds = []
    payment_intent = stripe_payment_intent('ch_test', amount: 1000)
    Stripe::PaymentIntent.stub :retrieve, payment_intent do
      Stripe::Refund.stub :create, proc { refunds << true } do
        yield refunds
      end
    end
  end

  def create_complete_order_with_ticket
    create_complete_order
    @ticket = @order.tickets.create!(event: @event, account: @attendee, ticket_type: @event.ticket_types.first, price: 0)
  end

  # A Stripe payment intent with one charge, of amount and amount_refunded cents. The default is more than any test's
  # refund, so refunds aren't capped at what's left unless a test sets it. With an application_fee (its id), the
  # charge answers that too
  def stripe_payment_intent(charge_id, amount: 1_000_000, amount_refunded: 0, application_fee: nil)
    charge = { id: charge_id, amount: amount, amount_refunded: amount_refunded }
    charge[:application_fee] = application_fee if application_fee
    api_object(charges: [api_object(**charge)])
  end
end
