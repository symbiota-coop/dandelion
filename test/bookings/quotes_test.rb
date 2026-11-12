require_relative '../test_config'

# Quote: what a booking costs, which the checkout form shows (POST /e/:slug/quote) and OrderBuilder charges
class QuotesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def grant_credit(account, amount:, currency: @event.currency)
    organisationship = @organisation.organisationships.find_or_create_by(account: account)
    organisationship.creditings.create!(account: @account, amount: amount, currency: currency)
  end

  def donations_to_dandelion!
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    @event.reload
    assert @event.donations_to_dandelion?
  end

  def make_monthly_donor(account, discount: 20)
    @organisation.organisation_tiers.create!(name: 'Gold', threshold: 10, discount: discount)
    FactoryBot.create(:organisationship, organisation: @organisation, account: account, monthly_donation_method: 'Other',
                                         monthly_donation_amount: 20, monthly_donation_currency: 'GBP')
  end

  def ticket_type_id(index = 0)
    @event.ticket_types[index].id.to_s
  end

  # A quote for the buyer, signed in (so with their credit), paying by card as the checkout form does
  def quote_for(buyer, **args)
    Quote.new(event: @event, account: buyer, credit: true, payment_method: 'stripe', **args).validate!
  end

  # Books what quote_for quoted through OrderBuilder, signed in as the buyer, and gives the order it made
  def book(buyer, quantities:, prices: {}, discount_code: nil, donation_amount: nil)
    builder = OrderBuilder.new(event: @event, buyer: { name: buyer.name, email: buyer.email }, signed_in_account: buyer, quantities: quantities,
                               prices: prices, discount_code: discount_code, donation_amount: donation_amount, payment_method: 'stripe')
    with_stubbed_stripe_session { builder.call }
    builder.order.reload
  end

  # As assert_equal, for an expected nil too
  def assert_same_value(expected, actual)
    expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
  end

  def assert_quote(quote, tickets:, total:, credit: nil, fixed_discount: nil, donation: nil)
    assert_equal tickets, quote.discounted_ticket_revenue.cents.to_f / 100
    assert_same_value credit, quote.credit_applied
    assert_same_value fixed_discount, quote.fixed_discount_applied
    assert_same_value donation, quote.donation
    assert_in_delta total, quote.total, 0.001
    assert_equal total.positive?, quote.payment_required?
  end

  # What OrderBuilder stored for the order, as the quote says it would be
  def assert_order_matches(quote, order)
    assert_equal quote.discounted_ticket_revenue, order.discounted_ticket_revenue
    assert_equal quote.donation_revenue, order.donation_revenue
    assert_same_value quote.percentage_discount, order.percentage_discount
    assert_same_value quote.percentage_discount_monthly_donor, order.percentage_discount_monthly_donor
    assert_same_value quote.credit_applied, order.credit_applied
    assert_same_value quote.fixed_discount_applied, order.fixed_discount_applied
    assert_equal quote.currency, order.currency
    assert_in_delta quote.total, order.total, 0.0001
    assert_equal quote.payment_required?, !order.payment_completed
  end

  # Each case quotes a booking, then books it through OrderBuilder, which must store what the quote said
  def assert_quoted_and_booked(buyer, **args, &)
    quote = quote_for(buyer, **args)
    yield quote
    assert_order_matches(quote, book(buyer, **args))
  end

  setup do
    @buyer = FactoryBot.create(:account)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Quote, and OrderBuilder booking the same thing
  # ═══════════════════════════════════════════════════════════════════════════

  test 'a fixed price' do
    create_event(prices: [10], suggested_donation: 0)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '2' }) do |quote|
      assert_quote quote, tickets: 20, total: 20
      assert_equal 20, quote.subtotal
    end
  end

  test 'range and pay-what-you-want prices' do
    create_event(prices: ['10-100', nil], suggested_donation: 0)
    quantities = { ticket_type_id(0) => '1', ticket_type_id(1) => '2' }
    prices = { ticket_type_id(0) => '50', ticket_type_id(1) => '7.5' }
    assert_quoted_and_booked(@buyer, quantities: quantities, prices: prices) do |quote|
      assert_quote quote, tickets: 65, total: 65
    end
  end

  test 'a free ticket needs no payment' do
    create_event(prices: [0], suggested_donation: 0)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }) do |quote|
      assert_quote quote, tickets: 0, total: 0
    end
  end

  test "a discount code's percentage comes off each ticket, to the penny" do
    create_event(prices: [7.77], suggested_donation: 0)
    FactoryBot.create(:discount_code, codeable: @event, code: 'FIFTEEN', percentage_discount: 15)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '3' }, discount_code: 'fifteen') do |quote|
      # 6.6045 rounds to 6.60 a ticket, rather than the three coming to 19.81
      assert_equal 15, quote.percentage_discount
      assert_quote quote, tickets: 19.80, total: 19.80
    end
  end

  test "a discount code's fixed discount comes off the order, up to its total" do
    create_event(prices: [10], suggested_donation: 0)
    FactoryBot.create(:discount_code, codeable: @event, code: 'THREE', fixed_discount_amount: 3, fixed_discount_currency: 'GBP')
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }, discount_code: 'THREE') do |quote|
      assert_quote quote, tickets: 10, fixed_discount: 3.0, total: 7
    end
  end

  test 'a fixed discount larger than the order pays for it' do
    create_event(prices: [10], suggested_donation: 0)
    FactoryBot.create(:discount_code, codeable: @event, code: 'BIG', fixed_discount_amount: 25, fixed_discount_currency: 'GBP')
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }, discount_code: 'BIG') do |quote|
      assert_quote quote, tickets: 10, fixed_discount: 10.0, total: 0
    end
  end

  test "a fixed discount isn't applied to an order that another order used its code up before" do
    create_event(prices: [10], suggested_donation: 0)
    code = FactoryBot.create(:discount_code, codeable: @event, code: 'LAST', fixed_discount_amount: 3, fixed_discount_currency: 'GBP', maximum_uses: 1)
    builder = OrderBuilder.new(event: @event, buyer: { name: @buyer.name, email: @buyer.email }, signed_in_account: @buyer,
                               quantities: { ticket_type_id => '1' }, discount_code: 'LAST', payment_method: 'stripe')
    # Between the quote and the order, another booking takes the code's last use
    other_order = nil
    builder.define_singleton_method(:create_order) do
      other_order = @event.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', discount_code: code)
      super()
    end

    error = assert_raises(OrderBuilder::DiscountCodeInvalid) { with_stubbed_stripe_session { builder.call } }
    assert_equal 'The discount code LAST has been used up.', error.message
    assert_equal [other_order], Order.and(event_id: @event.id).to_a
    assert_equal 0, @event.tickets.count
  end

  test "a fixed discount and credit in another currency are exchanged into the order's" do
    create_event(prices: [10], suggested_donation: 0)
    FactoryBot.create(:discount_code, codeable: @event, code: 'EURO', fixed_discount_amount: 5, fixed_discount_currency: 'EUR')
    # The organisation's credit is in its own currency
    @organisation.set(currency: 'EUR')
    rates = { %w[EUR GBP] => 0.8, %w[GBP EUR] => 1.25 }
    Money.default_bank.stub(:get_rate, ->(from, to, *) { rates.fetch([from.to_s, to.to_s]) }) do
      grant_credit(@buyer, amount: 5, currency: 'EUR')
      assert_equal Money.new(500, 'EUR'), @organisation.organisationships.find_by(account: @buyer).credit_balance
      assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }, discount_code: 'EURO') do |quote|
        assert_quote quote, tickets: 10, credit: 4.0, fixed_discount: 4.0, total: 2
      end
    end
  end

  test "a monthly donor's discount, unless the event has no discounts or a code takes a percentage off" do
    create_event(prices: [10], suggested_donation: 0)
    make_monthly_donor(@buyer, discount: 20)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }) do |quote|
      assert_equal 20, quote.percentage_discount_monthly_donor
      assert_quote quote, tickets: 8, total: 8
    end

    FactoryBot.create(:discount_code, codeable: @event, code: 'TEN', percentage_discount: 10)
    quote = quote_for(@buyer, quantities: { ticket_type_id => '1' }, discount_code: 'TEN')
    assert_nil quote.percentage_discount_monthly_donor
    assert_quote quote, tickets: 9, total: 9

    @event.set(no_discounts: true)
    quote = quote_for(@buyer, quantities: { ticket_type_id => '1' })
    assert_nil quote.percentage_discount_monthly_donor
    assert_quote quote, tickets: 10, total: 10
  end

  test 'credit smaller than the total' do
    create_event(prices: [10], suggested_donation: 0)
    grant_credit(@buyer, amount: 4)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }) do |quote|
      assert_quote quote, tickets: 10, credit: 4.0, total: 6
    end
  end

  test 'credit larger than the total pays for it' do
    create_event(prices: [10], suggested_donation: 0)
    grant_credit(@buyer, amount: 15)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }) do |quote|
      assert_quote quote, tickets: 10, credit: 10.0, total: 0
    end
  end

  test 'credit is only for the buyer signed in' do
    create_event(prices: [10], suggested_donation: 0)
    grant_credit(@buyer, amount: 4)
    quote = Quote.new(event: @event, account: @buyer, credit: false, quantities: { ticket_type_id => '1' })
    assert_quote quote, tickets: 10, total: 10
  end

  test 'credit pays for a donation to the organisation too' do
    create_event(prices: [10], suggested_donation: 5)
    refute @event.donations_to_dandelion?
    grant_credit(@buyer, amount: 12)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }, donation_amount: '5') do |quote|
      assert_quote quote, tickets: 10, donation: 5.0, credit: 12.0, total: 3
      assert_equal 15, quote.subtotal
    end
  end

  test 'credit pays for the tickets, and a donation to Dandelion is added to what it leaves' do
    create_event(prices: [10])
    donations_to_dandelion!
    grant_credit(@buyer, amount: 5)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }, donation_amount: '2') do |quote|
      assert_quote quote, tickets: 10, donation: 2.0, credit: 5.0, total: 7
      assert quote.payment_required_without_donation?
    end
  end

  test 'tickets that credit pays for in full on a donations-to-Dandelion event are booked without the donation' do
    create_event(prices: [10])
    donations_to_dandelion!
    grant_credit(@buyer, amount: 15)
    assert_quoted_and_booked(@buyer, quantities: { ticket_type_id => '1' }, donation_amount: '1') do |quote|
      assert_quote quote, tickets: 10, credit: 10.0, total: 0
      refute quote.payment_required_without_donation?
    end
  end

  test 'a donation to Dandelion on free tickets is still charged, and credit takes nothing off it' do
    create_event(prices: [0, 10])
    donations_to_dandelion!
    grant_credit(@buyer, amount: 2)
    free = @event.ticket_types.find_by(price: 0).id.to_s
    assert_quoted_and_booked(@buyer, quantities: { free => '1' }, donation_amount: '5') do |quote|
      assert_quote quote, tickets: 0, credit: 0.0, donation: 5.0, total: 5
      refute quote.payment_required_without_donation?
    end
  end

  test "a quote says whether a payment is needed without the donation before it's asked anything else" do
    create_event(prices: [10])
    donations_to_dandelion!
    assert Quote.new(event: @event, quantities: { ticket_type_id => '1' }, donation_amount: '2').payment_required_without_donation?
  end

  test "a payment method that can't take a donation to Dandelion drops it" do
    create_event(prices: [10])
    donations_to_dandelion!
    quote = Quote.new(event: @event, payment_method: 'rsvp', quantities: { ticket_type_id => '1' }, donation_amount: '2')
    assert quote.ignore_dandelion_donation?
    assert_quote quote, tickets: 10, total: 10
  end

  test "an agent booking's default donation to Dandelion is the smallest unit, unless the tickets are free" do
    create_event(prices: [0, 10])
    donations_to_dandelion!
    paid = @event.ticket_types.find_by(price: 10).id.to_s
    free = @event.ticket_types.find_by(price: 0).id.to_s
    quote = Quote.new(event: @event, payment_method: 'stripe', quantities: { paid => '1' }, default_dandelion_donation: true)
    assert_quote quote, tickets: 10, donation: 1.0, total: 11
    quote = Quote.new(event: @event, payment_method: 'stripe', quantities: { free => '1' }, default_dandelion_donation: true)
    assert_quote quote, tickets: 0, total: 0
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # What a quote refuses, as OrderBuilder does
  # ═══════════════════════════════════════════════════════════════════════════

  test 'a quote refuses a code that is used up or not for the tickets chosen' do
    create_event(prices: [10, 20], suggested_donation: 0)
    @event.ticket_types[0].set(name: 'Standard')
    @event.ticket_types[1].set(name: 'Concession')
    FactoryBot.create(:discount_code, codeable: @event, code: 'CONC', percentage_discount: 50, filter: 'concession')
    used_up = FactoryBot.create(:discount_code, codeable: @event, code: 'ONCE', percentage_discount: 50, maximum_uses: 1)
    @event.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', discount_code: used_up)

    error = assert_raises(OrderBuilder::DiscountCodeInvalid) { quote_for(@buyer, quantities: { ticket_type_id(0) => '1' }, discount_code: 'CONC') }
    assert_includes error.message, 'only applies to ticket types whose names include concession'
    assert_equal 10, quote_for(@buyer, quantities: { ticket_type_id(1) => '1' }, discount_code: 'CONC').total
    error = assert_raises(OrderBuilder::DiscountCodeInvalid) { quote_for(@buyer, quantities: { ticket_type_id(0) => '1' }, discount_code: 'ONCE') }
    assert_includes error.message, 'used up'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # POST /e/:slug/quote
  # ═══════════════════════════════════════════════════════════════════════════

  def post_quote(ticket_form)
    header 'Accept', 'application/json'
    post "/e/#{@event.slug}/quote", ticketForm: ticket_form
  end

  test "the quote route gives the form's choices' price, with the signed-in buyer's credit" do
    create_event(prices: [10], suggested_donation: 5)
    FactoryBot.create(:discount_code, codeable: @event, code: 'HALF', percentage_discount: 50)
    grant_credit(@buyer, amount: 2)

    post_quote(quantities: { ticket_type_id => '2' }, applied_discount_code: 'HALF', donation_amount: '3')
    assert_equal 200, last_response.status
    # Signed out, no credit
    assert_equal({ 'tickets' => 10.0, 'donation' => 3.0, 'credit_applied' => nil, 'subtotal' => 13.0, 'total' => 13.0, 'payment_required' => true },
                 JSON.parse(last_response.body).slice('tickets', 'donation', 'credit_applied', 'subtotal', 'total', 'payment_required'))

    sign_in_with_rack(@buyer)
    post_quote(quantities: { ticket_type_id => '2' }, applied_discount_code: 'HALF', donation_amount: '3')
    assert_equal 200, last_response.status
    json = JSON.parse(last_response.body)
    assert_equal 2.0, json['credit_applied']
    assert_equal 11.0, json['total']
    assert_equal 50, json['percentage_discount']

    # Nothing chosen yet costs nothing
    post_quote({})
    assert_equal 200, last_response.status
    assert_equal 0.0, JSON.parse(last_response.body)['total']
  end

  test "the quote route refuses a price too big to be one, and counts a quantity that isn't a number as none" do
    create_event(prices: [nil], suggested_donation: 0)

    post_quote(quantities: { ticket_type_id => '1' }, prices: { ticket_type_id => '1e400' })
    assert_equal 400, last_response.status
    assert_includes JSON.parse(last_response.body)['error'], 'Choose a price per ticket'

    post_quote(quantities: { ticket_type_id => { 'x' => '1' } })
    assert_equal 200, last_response.status
    assert_equal 0.0, JSON.parse(last_response.body)['total']
  end

  test 'the quote route refuses what the purchase would refuse' do
    create_event(prices: [10, '10-100'], suggested_donation: 0)
    hidden = FactoryBot.create(:ticket_type, event: @event, price_or_range: 5, hidden: true)

    post_quote(quantities: { hidden.id.to_s => '1' })
    assert_equal 404, last_response.status
    post_quote(quantities: { hidden.id.to_s => '1' }, ticket_type_id: hidden.public_id)
    assert_equal 200, last_response.status
    assert_equal 5.0, JSON.parse(last_response.body)['total']

    post_quote(quantities: { ticket_type_id(1) => '1' }, prices: { ticket_type_id(1) => '150' })
    assert_equal 400, last_response.status
    assert_includes JSON.parse(last_response.body)['error'], 'Choose a price per ticket'

    post_quote(quantities: { ticket_type_id(0) => '1' }, applied_discount_code: 'NOPE')
    assert_equal 400, last_response.status
    assert_equal 'The discount code NOPE is not valid for this event.', JSON.parse(last_response.body)['error']

    # No donation box
    @event.set(suggested_donation: nil)
    post_quote(quantities: { ticket_type_id(0) => '1' }, donation_amount: '5')
    assert_equal 400, last_response.status

    @event.set(locked: true)
    post_quote(quantities: { ticket_type_id(0) => '1' })
    assert_equal 403, last_response.status

    @event.set(locked: false, monthly_donors_only: true)
    post_quote(quantities: { ticket_type_id(0) => '1' })
    assert_equal 403, last_response.status

    post '/e/no-such-event/quote', ticketForm: { quantities: { ticket_type_id(0) => '1' } }
    assert_equal 404, last_response.status
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # The checkout form
  # ═══════════════════════════════════════════════════════════════════════════

  test "the checkout form shows the quote's total as quantities and the donation change" do
    create_event(prices: [10], suggested_donation: 5)
    grant_credit(@buyer, amount: 4)
    sign_in(@buyer)
    visit "/e/#{@event.slug}"

    select 2, from: "quantities[#{ticket_type_id}]"
    fill_in 'donation_amount', with: 3
    quote = Quote.new(event: @event, account: @buyer, credit: true, quantities: { ticket_type_id => '2' }, donation_amount: '3')
    assert_equal 19, quote.total
    assert page.has_button? "Pay £#{format('%.2f', quote.total)}"
    assert_equal format('%.2f', quote.subtotal), find_field('totalDisplay', disabled: true).value
    assert_equal format('%.2f', quote.total), find_field('balance', disabled: true).value

    select 1, from: "quantities[#{ticket_type_id}]"
    assert page.has_button? 'Pay £9.00'
    assert_equal '13.00', find_field('totalDisplay', disabled: true).value
  end

  test "the checkout form says why it can't price the choices, and waits for them to be changed" do
    create_event(prices: [10, 20], suggested_donation: 0)
    visit "/e/#{@event.slug}"

    select 1, from: "quantities[#{ticket_type_id(0)}]"
    assert page.has_button? 'Pay £10.00', disabled: false

    # Sales of the other ticket type end while the page is open
    @event.ticket_types[1].set(sales_end: 1.minute.ago)
    select 1, from: "quantities[#{ticket_type_id(1)}]"
    assert page.has_css? '#quote-error', text: 'Sales of that ticket type have ended.'
    # The button still shows the last quote's amount, so it can't be pressed
    assert page.has_button? 'Pay £10.00', disabled: true

    select 0, from: "quantities[#{ticket_type_id(1)}]"
    assert page.has_button? 'Pay £10.00', disabled: false
    assert page.has_no_css? '#quote-error'
  end

  test "the checkout form keeps payment waiting while a quote can't be had, and tries again" do
    create_event(prices: [10], suggested_donation: 0)
    visit "/e/#{@event.slug}"

    select 1, from: "quantities[#{ticket_type_id}]"
    assert page.has_button? 'Pay £10.00', disabled: false

    unavailable = OrderBuilder::Error.new
    unavailable.define_singleton_method(:status) { 503 }
    Quote.stub(:new, ->(**) { raise unavailable }) do
      select 2, from: "quantities[#{ticket_type_id}]"
      assert page.has_css? '#quote-error', text: 'Updating the price'
      # Not the £10 the button showed for one ticket, while the order would be for two
      assert page.has_button? 'Pay £10.00', disabled: true
    end

    assert page.has_button? 'Pay £20.00', disabled: false
    assert page.has_no_css? '#quote-error'
  end
end
