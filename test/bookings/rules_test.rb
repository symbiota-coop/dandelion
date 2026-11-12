require_relative '../test_config'
require_relative '../helpers/bookings_helpers'

# What a purchase is refused for: who may book, quantities, prices, answers and booking twice
class EventBookingRulesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include BookingsHelpers

  # A ticket the account already holds, booked earlier
  def book_ticket_for(account)
    order = @event.orders.create!(account: account, currency: @event.currency, value: 0, payment_completed: true)
    order.tickets.create!(event: @event, account: account, ticket_type: @event.ticket_types.first, price: 0, payment_completed: true)
  end

  test 'purchase is forbidden when the event is locked and the buyer cannot view the page' do
    covers 'events/locked-events-admins-can-buy@145a18'
    create_full_event_hierarchy(event_options: { prices: [0], locked: true })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)

    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'an event admin books a locked event' do
    covers 'events/locked-events-admins-can-buy@145a18'
    create_full_event_hierarchy(event_options: { prices: [0], locked: true })

    sign_in(@account)
    visit "/e/#{@event.slug}"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert @event.orders.find_by(account: @account)
  end

  test 'purchase is forbidden when monthly_donors_only and the buyer is not a signed-in donor' do
    covers 'organisations/monthly-donors-only-events@571550'
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    assert_equal 403, last_response.status

    sign_in_with_rack(buyer)
    post_purchase(@event, buyer)
    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'a signed-in monthly donor books an event only for monthly donors' do
    covers 'organisations/monthly-donors-only-events@571550'
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })
    buyer = FactoryBot.create(:account)
    FactoryBot.create(:organisationship, organisation: @organisation, account: buyer, monthly_donation_method: 'Other', monthly_donation_amount: 1)

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert @event.orders.find_by(account: buyer)
  end

  test 'an event only for monthly donors offers no booking to someone signed in who is not one' do
    covers 'organisations/monthly-donors-only-events@571550'
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })

    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}"
    assert page.has_content? 'You must be a monthly donor to'
    assert page.has_no_button? 'RSVP'
  end

  test 'purchase is forbidden when the activity is closed and the buyer is not a member' do
    covers 'events/application-gates-purchase@891514', 'organisations/application-only-activities@7b2afe'
    create_full_event_hierarchy(event_options: { prices: [0] })
    @activity.set(privacy: 'closed')
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    assert_equal 403, last_response.status

    sign_in_with_rack(buyer)
    post_purchase(@event, buyer)
    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test "a signed-in member of a closed activity books the activity's event" do
    covers 'events/application-gates-purchase@891514', 'organisations/application-only-activities@7b2afe'
    create_full_event_hierarchy(event_options: { prices: [0] })
    @activity.set(privacy: 'closed')
    buyer = FactoryBot.create(:account)
    @activity.activityships.create!(account: buyer)

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert @event.orders.find_by(account: buyer)
  end

  test "a closed activity's event offers no booking to someone signed in who is not a member" do
    covers 'events/application-gates-purchase@891514', 'organisations/application-only-activities@7b2afe'
    create_full_event_hierarchy(event_options: { prices: [0] })
    @activity.set(privacy: 'closed')

    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}"
    assert page.has_content? 'You must be a member of the'
    assert page.has_no_button? 'RSVP'
  end

  test 'anyone books an open unlocked event' do
    create_full_event_hierarchy(event_options: { prices: [0] })
    buyer = FactoryBot.create(:account)

    visit "/e/#{@event.slug}"
    fill_in 'account_name', with: buyer.name
    fill_in 'account_email', with: buyer.email
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert @event.orders.find_by(account: buyer)
  end

  test 'purchase is rejected when quantity exceeds max_quantity_per_transaction' do
    create_event(prices: [0])
    @event.ticket_types.first.set(quantity: 10, max_quantity_per_transaction: 1)
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer, quantity: 2)

    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count
    assert_equal 0, @event.tickets.count
  end

  test 'purchase is rejected, without reporting an error, when the ticket type is no longer on sale' do
    create_event(prices: [0])
    @event.ticket_types.first.set(sales_end: 1.day.ago)
    buyer = FactoryBot.create(:account)

    reported = []
    ErrorReporting.stub(:capture_exception, ->(e, **) { reported << e }) do
      post_purchase(@event, buyer)
    end

    assert_equal 400, last_response.status
    assert_empty reported
    assert_equal 0, @event.orders.count
  end

  test 'purchase is rejected, without reporting an error, when no tickets are chosen' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)

    reported = []
    ErrorReporting.stub(:capture_exception, ->(e, **) { reported << e }) do
      post_purchase(@event, buyer, quantity: 0)
    end

    assert_equal 400, last_response.status
    assert_equal 'Choose at least one ticket.', JSON.parse(last_response.body)['error']
    assert_empty reported
    assert_equal 0, @event.orders.count
  end

  test 'purchase needs at least the minimum donation' do
    covers 'events/contribution-keeping-up@ab2a3a', 'events/checkout-donation-box-when-suggested@99f9e3'
    create_event(prices: [0], suggested_donation: 10, minimum_donation: 5)
    assert_equal 5, @event.minimum_donation
    refute @event.donations_to_dandelion?
    buyer = FactoryBot.create(:account)
    purchase = lambda do |donation_amount|
      header 'Accept', 'application/json'
      post "/e/#{@event.slug}/purchase",
           ticketForm: { quantities: { @event.ticket_types.first.id.to_s => '1' }, donation_amount: donation_amount },
           detailsForm: { payment_method: 'stripe', account: { name: buyer.name, email: buyer.email } }
    end

    purchase.call('')
    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count

    with_stubbed_stripe_session do
      purchase.call('5')
    end
    assert_equal 200, last_response.status
    assert_equal 5, @event.orders.first.donations.first.amount
  end

  test 'the Stripe payment page closes when the order stops holding its tickets' do
    create_event(prices: [10], suggested_donation: 0)

    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    session_params = nil
    pay_by_card('Pay £10.00') { |params| session_params = params }
    assert_equal (@event.orders.first.created_at + Order::UNPAID_HOLD).to_i, session_params[:expires_at]
  end

  test "purchase checks answers and stores them with the event's own questions" do
    create_event(prices: [0], questions: "T-shirt size <S, M, L>*\nDietary requirements")

    post_checkout(details_form: { payment_method: 'rsvp', answers: { '1' => 'None' } })
    assert_equal 400, last_response.status

    post_checkout(details_form: { payment_method: 'rsvp', answers: { '0' => 'XL' } })
    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count

    post_checkout(details_form: { payment_method: 'rsvp', answers: { '0' => 'M', '1' => 'None' }, questions: { '0' => 'Forged question', '1' => 'Another' } })
    assert_equal 200, last_response.status
    assert_equal [['T-shirt size <S, M, L>*', 'M'], ['Dietary requirements', 'None']], @event.orders.last.answers
  end

  test 'purchase needs a price within range for range and pay-what-you-want tickets' do
    covers 'events/price-range-slider@693b77'
    create_event(prices: ['10-100'], suggested_donation: 0)
    ticket_type_id = @event.ticket_types.first.id.to_s

    # Rather than booking at £0, or at the nearest end of the range
    post_checkout
    assert_equal 400, last_response.status
    post_checkout(ticket_form: { prices: { ticket_type_id => '150' } })
    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count

    with_stubbed_stripe_session do
      post_checkout(ticket_form: { prices: { ticket_type_id => '25' } })
    end
    assert_equal 200, last_response.status
    assert_equal 25, @event.tickets.first.price
  end

  test 'purchase refuses a discount code that is not valid, rather than charging the full price' do
    create_event(prices: [10], suggested_donation: 0)
    FactoryBot.create(:discount_code, codeable: @event, code: 'HALF', percentage_discount: 50)

    post_checkout(ticket_form: { applied_discount_code: 'NOPE' })
    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count

    with_stubbed_stripe_session do
      post_checkout(ticket_form: { applied_discount_code: 'HALF' })
    end
    assert_equal 200, last_response.status
    assert_equal 5, @event.orders.last.total
  end

  test '?via= on the event URL is recorded on the order and shown on the Orders page' do
    covers 'events/via-shown-on-orders@f74769'
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)

    visit "/e/#{@event.slug}?via=may-newsletter"
    fill_in 'account_name', with: buyer.name
    fill_in 'account_email', with: buyer.email
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert_equal 'may-newsletter', @event.orders.find_by(account: buyer).via

    sign_in(@account)
    visit "/e/#{@event.slug}/orders"
    assert page.has_content? buyer.name
    assert page.has_content? 'may-newsletter'
  end

  test 'checkout offers, and books, up to max_quantity_per_transaction' do
    create_event(prices: [0], always_show_full_ticket_form: true)
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 10, max_quantity_per_transaction: 2)
    buyer = FactoryBot.create(:account)

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    assert page.has_select? "quantities[#{ticket_type.id}]", options: %w[0 1 2]
    select 2, from: "quantities[#{ticket_type.id}]"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert_equal 2, @event.orders.find_by(account: buyer).tickets.count
  end

  test 'purchase aggregates equivalent ticket type IDs before checking the quantity limit' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 10, max_quantity_per_transaction: 1)
    buyer = FactoryBot.create(:account)
    ticket_type_id = ticket_type.id.to_s

    post_purchase(
      @event,
      buyer,
      quantities: {
        ticket_type_id => '1',
        ticket_type_id.upcase => '1'
      }
    )

    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count
    assert_equal 0, @event.tickets.count
  end

  test 'purchase allows equivalent ticket type IDs up to the initial availability' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 2)
    buyer = FactoryBot.create(:account)
    ticket_type_id = ticket_type.id.to_s

    post_purchase(
      @event,
      buyer,
      quantities: {
        ticket_type_id => '1',
        ticket_type_id.upcase => '1'
      }
    )

    assert_equal 200, last_response.status
    assert_equal 2, @event.orders.find_by(account: buyer).tickets.count
  end

  test 'checkout asks before booking again for an account that already holds a ticket, and books nothing if they go back' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    book_ticket_for(buyer)

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    message = dismiss_confirm { click_button 'RSVP' }
    assert_includes message, "A ticket to #{@event.name} has already been booked for #{buyer.email}."
    assert page.has_button? 'RSVP'
    assert_equal 1, @event.orders.count
  end

  test 'checkout books another ticket once the account confirms it wants one' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    book_ticket_for(buyer)

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    message = accept_confirm { click_button 'RSVP' }
    assert_includes message, 'has already been booked'
    assert page.has_content? 'Thanks for booking'
    assert_equal 2, @event.orders.count
  end

  test 'checkout asks before booking when a ticket was already ordered for that email' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    book_ticket_for(FactoryBot.create(:account)).set(email: buyer.email)

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    message = dismiss_confirm { click_button 'RSVP' }
    assert_includes message, "has already been booked for #{buyer.email}"
    assert_equal 1, @event.orders.count
  end

  test "checkout doesn't ask when the account's earlier ticket was reassigned to someone else" do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    book_ticket_for(buyer).set(email: 'friend@example.com')

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    refuse_confirmations
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert_equal 2, @event.orders.count
  end

  test 'ticket_form_only does not render the purchase form when the buyer cannot purchase' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })

    get "/e/#{@event.slug}", ticket_form_only: 1

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'id="select-tickets"'
    assert_includes last_response.body, 'monthly donor'
  end
end
