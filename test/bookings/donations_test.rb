require_relative '../test_config'
require_relative '../helpers/bookings_helpers'

# Donations at checkout, to Dandelion or the organisation, and paying with credit
class EventBookingDonationsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include BookingsHelpers

  test 'purchase refuses a donation to Dandelion below the smallest unit' do
    create_event(prices: [10])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert @event.reload.donations_to_dandelion?

    post_checkout(ticket_form: { donation_amount: '0.1' })
    assert_equal 400, last_response.status
    assert_equal 'A donation to Dandelion must be at least £1, or nothing.', JSON.parse(last_response.body)['error']
    assert_equal 0, @event.orders.count

    with_stubbed_stripe_session { post_checkout(ticket_form: { donation_amount: '1' }) }
    assert_equal 200, last_response.status
    assert_equal 1, @event.orders.last.donations.first.amount
  end

  test "purchase refuses a donation the event doesn't take" do
    covers 'events/checkout-donation-box-when-suggested@99f9e3'
    create_event(prices: [10])
    @event.set(suggested_donation: nil)

    post_checkout(ticket_form: { donation_amount: '5' })

    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'with Stripe Connect, checkout donations go to Dandelion while the organisation is behind on its contribution' do
    covers 'events/contribution-keeping-up@ab2a3a', 'events/checkout-donations-to-dandelion@f1a028', 'events/checkout-donations-default-to-dandelion@61777f'
    create_event(prices: [10])
    # A new organisation owes nothing yet, so it starts paid up
    assert @organisation.paid_up
    @organisation.set(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert_equal 'dandelion', @event.reload.checkout_donation[:to]

    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}"
    assert page.has_content? 'Add a donation to Dandelion'
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: 3
    session_params = nil
    pay_by_card('Pay £13.00') { |params| session_params = params }
    order = @event.orders.last
    assert order.application_fee_paid_to_dandelion
    assert_equal 13, order.total
    # The donation is Dandelion's application fee, kept from the payment to the organisation's Stripe account
    assert_equal 300, session_params[:payment_intent_data][:application_fee_amount]

    # Once the organisation keeps up with its contribution, they go to it
    @organisation.set(paid_up: true)
    refute @event.reload.donations_to_dandelion?
    assert_nil @event.checkout_donation
  end

  test "with Stripe Connect, a free event's suggested donation goes to Dandelion while the organisation is behind" do
    covers 'events/checkout-donations-to-dandelion@f1a028', 'events/checkout-donation-box-when-suggested@99f9e3'
    create_event(prices: [0, 0], suggested_donation: 5)
    @organisation.set(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert_equal 'dandelion', @event.reload.checkout_donation[:to]

    get "/e/#{@event.slug}"
    assert_includes last_response.body, 'Add a donation to Dandelion'

    # Once the organisation keeps up with its contribution, it goes to the organisation
    @organisation.set(paid_up: true)
    assert_equal({ to: 'organisation', suggested: 5 }, @event.reload.checkout_donation.slice(:to, :suggested))
    get "/e/#{@event.slug}"
    assert_includes last_response.body, "Add a donation to #{@organisation.name}"
  end

  test 'an event with one free ticket type books in one click, with no donation box, unless it always shows the full form' do
    covers 'events/single-free-ticket-no-donation-box@7c1dde'
    create_event(prices: [0], suggested_donation: 5)
    @organisation.set(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert @event.reload.checkout_donation

    get "/e/#{@event.slug}"
    assert_includes last_response.body, "quantities[#{@event.ticket_types.first.id}]"
    refute_includes last_response.body, 'id="donation_amount"'

    @event.set(always_show_full_ticket_form: true)
    get "/e/#{@event.slug}"
    assert_includes last_response.body, 'id="donation_amount"'
  end

  test 'checkout donations go to Dandelion only with Stripe Connect, and otherwise always to the organisation' do
    covers 'events/checkout-donations-default-to-dandelion@61777f'
    create_event(prices: [10], suggested_donation: 5)
    connect_json = { 'stripe_user_id' => 'acct_connect' }.to_json
    # Behind on its contribution throughout
    @organisation.set(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: connect_json, paid_up: false)
    assert_equal 'dandelion', @event.reload.checkout_donation[:to]

    # Its own Stripe keys
    @organisation.set(stripe_pk: 'pk_test_own', stripe_sk: 'sk_test_own')
    assert_equal 'organisation', @event.reload.checkout_donation[:to]

    # No Stripe at all
    @organisation.set(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: nil)
    assert_equal 'organisation', @event.reload.checkout_donation[:to]
  end

  test 'checkouts have no donation box when donations would go to the organisation and it suggests none' do
    covers 'events/checkout-donation-box-when-suggested@99f9e3'
    create_event(prices: [10])
    @event.set(suggested_donation: nil)
    refute @event.reload.donations_to_dandelion?
    assert_nil @event.checkout_donation

    get "/e/#{@event.slug}"
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'id="donation_amount"'
  end

  test 'credit pays for tickets, not a donation to Dandelion' do
    create_event(prices: [10])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert @event.reload.donations_to_dandelion?
    buyer = FactoryBot.create(:account)
    grant_credit(buyer, amount: 15)
    sign_in_with_rack(buyer)

    # Credit covers the tickets, so the order completes with no payment, which a donation to Dandelion would need
    post_checkout(ticket_form: { donation_amount: '1' }, buyer: buyer)
    assert_equal 200, last_response.status
    order = @event.orders.find_by(account: buyer)
    assert_equal 10, order.credit_applied
    assert_equal 0, order.total
    assert order.payment_completed
    assert_equal 0, order.donations.count
  end

  test 'checkout books tickets credit pays for, without a donation to Dandelion' do
    covers 'organisations/credit-applied-at-checkout@ebe0b1'
    create_event(prices: [10])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert @event.reload.donations_to_dandelion?
    grant_credit(@account, amount: 10)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"

    # The donation the form starts with isn't added to what's left to pay
    assert page.has_button? 'Use credit'
    assert page.has_no_button? 'Pay £'
    click_button 'Use credit'
    assert page.has_content? 'Thanks for booking'

    order = @event.orders.find_by(account: @account)
    assert_equal 10, order.credit_applied
    assert order.payment_completed
    assert_equal 0, order.donations.count
  end

  test 'checkout adds a donation to Dandelion to what credit leaves to pay' do
    create_event(prices: [10])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    grant_credit(@account, amount: 5)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"

    fill_in 'donation_amount', with: (donation_amount = 2)
    assert page.has_button? "Pay £#{format('%.2f', 10 - 5 + donation_amount)}"
    pay_by_card("Pay £#{format('%.2f', 10 - 5 + donation_amount)}")

    order = @event.orders.find_by(account: @account)
    assert_equal 5, order.credit_applied
    assert_equal 7, order.total
    assert_equal donation_amount, order.donations.first.amount
  end

  test 'with free tickets, the checkout asks for the whole donation to Dandelion, taking no credit off it' do
    create_event(prices: [0, 10])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert @event.reload.donations_to_dandelion?
    grant_credit(@account, amount: 2)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.find_by(price: 0).id}]"

    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', donation_amount)}"
  end

  test "purchase does not apply another account's credit when signed in as someone else" do
    create_event(prices: [10], suggested_donation: 0)
    victim = FactoryBot.create(:account)
    attacker = FactoryBot.create(:account)
    grant_credit(victim, amount: 10)

    sign_in_with_rack(attacker)
    post_purchase(@event, victim)

    assert_equal 400, last_response.status
    order = @event.orders.unscoped.find_by(account: victim)
    assert_nil order&.credit_applied
  end

  # Totals

  test "an event's donation totals count only paid donations, as its ticket revenue counts only paid tickets" do
    create_event(prices: [10])
    donor = FactoryBot.create(:account)
    paid_order = @event.orders.create!(account: donor, currency: 'GBP', value: 5, payment_completed: true)
    @event.donations.create!(account: donor, order: paid_order, amount: 5, payment_completed: true)
    unpaid_order = @event.orders.create!(account: donor, currency: 'GBP', value: 20)
    @event.donations.create!(account: donor, order: unpaid_order, amount: 20)
    dandelion_order = @event.orders.create!(account: donor, currency: 'GBP', value: 3, payment_completed: true, application_fee_paid_to_dandelion: true)
    @event.donations.create!(account: donor, order: dandelion_order, amount: 3, payment_completed: true)

    event = Event.find(@event.id)
    assert_equal Money.new(800, 'GBP'), event.donation_revenue
    assert_equal Money.new(800, 'GBP'), event.donation_revenue(skip_transferred: true)
    assert_equal Money.new(500, 'GBP'), event.donation_revenue_less_application_fees_paid_to_dandelion
    assert_equal Money.new(800, 'GBP'), event.revenue

    # The stats table reads the same totals from rows read for many events at once
    preloaded = Event.preload_stats(Event.and(id: @event.id)).first
    assert_equal Money.new(800, 'GBP'), preloaded.donation_revenue
    assert_equal Money.new(500, 'GBP'), preloaded.donation_revenue_less_application_fees_paid_to_dandelion

    # Once the order is paid for, its donation counts
    unpaid_order.payment_completed!
    event = Event.find(@event.id)
    assert_equal Money.new(2800, 'GBP'), event.donation_revenue
    assert_equal Money.new(2500, 'GBP'), event.donation_revenue_less_application_fees_paid_to_dandelion
  end
end
