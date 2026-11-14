# Helpers the test files that book share (test/bookings, and the payments and webhooks that bookings start)
module BookingsHelpers
  # Books event as the checkout form does, as a JSON request: quantity of its first ticket type, paid by
  # payment_method, for account. ticket_form and details_form add to or replace what the two forms send
  def post_purchase(event = @event, account = FactoryBot.create(:account), payment_method: 'rsvp', quantity: 1, ticket_form: {}, details_form: {}, confirmed_duplicate: false)
    header 'Accept', 'application/json'
    post "/e/#{event.slug}/purchase",
         confirmed_duplicate: (confirmed_duplicate ? '1' : ''),
         ticketForm: { quantities: { event.ticket_types.first.id.to_s => quantity.to_s } }.merge(ticket_form),
         detailsForm: { payment_method: payment_method, account: { name: account.name, email: account.email } }.merge(details_form)
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

  # Gives account credit of amount with @organisation, granted by @account, in @event's currency unless another
  def grant_credit(account, amount:, currency: @event.currency)
    organisationship = @organisation.organisationships.find_or_create_by(account: account)
    organisationship.creditings.create!(account: @account, amount: amount, currency: currency)
  end
end
