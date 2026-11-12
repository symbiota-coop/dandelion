# Helpers the booking test files (test/bookings) share
module BookingsHelpers
  def post_purchase(event, account, quantity: 1, quantities: nil, confirmed_duplicate: false)
    ticket_type = event.ticket_types.first
    quantities ||= { ticket_type.id.to_s => quantity.to_s }
    header 'Accept', 'application/json'
    post "/e/#{event.slug}/purchase",
         confirmed_duplicate: (confirmed_duplicate ? '1' : ''),
         ticketForm: { quantities: quantities },
         detailsForm: {
           payment_method: 'rsvp',
           account: { name: account.name, email: account.email }
         }
  end

  # Pays by card with button, as far as Stripe Checkout. Yields the params the checkout session is created with
  def pay_by_card(button)
    record_stripe_redirect
    session = proc do |params, _opts|
      yield params if block_given?
      api_object(id: 'cs_test', payment_intent: 'pi_test', url: 'https://checkout.stripe.com/test')
    end
    Stripe::Checkout::Session.stub(:create, session) do
      click_button button
      assert has_checkout_session?('cs_test')
    end
  end

  # Were the page to ask the buyer to confirm, they'd go back to the form rather than book
  def refuse_confirmations
    execute_script 'window.confirm = function () { return false }'
  end

  def post_checkout(ticket_form: {}, details_form: {}, buyer: FactoryBot.create(:account))
    header 'Accept', 'application/json'
    post "/e/#{@event.slug}/purchase",
         ticketForm: { quantities: { @event.ticket_types.first.id.to_s => '1' } }.merge(ticket_form),
         detailsForm: { payment_method: 'stripe', account: { name: buyer.name, email: buyer.email } }.merge(details_form)
  end
end
