require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventBookingsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

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

  # A ticket the account already holds, booked earlier
  def book_ticket_for(account)
    order = @event.orders.create!(account: account, currency: @event.currency, value: 0, payment_completed: true)
    order.tickets.create!(event: @event, account: account, ticket_type: @event.ticket_types.first, price: 0, payment_completed: true)
  end

  test 'a hidden ticket type is offered, and booked, through its secret link' do
    create_event(prices: [0])
    hidden = @event.ticket_types.create!(name: 'Secret', price: 0, quantity: 10, hidden: true)

    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}?ticket_type_id=#{hidden.token}"
    assert page.has_content? 'Secret'
    select 1, from: "quantities[#{hidden.id}]"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert_equal 1, hidden.tickets.count

    # A legacy ticket type, with no token, by its id
    hidden.unset(:token)
    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}?ticket_type_id=#{hidden.id}"
    assert page.has_content? 'Secret'
    select 1, from: "quantities[#{hidden.id}]"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert_equal 2, hidden.tickets.count
  end

  test 'hidden ticket types can only be bought with their secret link' do
    create_event(prices: [0])
    hidden = @event.ticket_types.create!(name: 'Secret', price: 0, quantity: 10, hidden: true)
    buyer = FactoryBot.create(:account)
    purchase = lambda do |ticket_type_id|
      header 'Accept', 'application/json'
      post "/e/#{@event.slug}/purchase",
           ticketForm: { quantities: { hidden.id.to_s => '1' }, ticket_type_id: ticket_type_id },
           detailsForm: { payment_method: 'rsvp', account: { name: buyer.name, email: buyer.email } }
    end

    purchase.call(nil)
    assert_equal 404, last_response.status
    purchase.call(hidden.id.to_s)
    assert_equal 404, last_response.status
    assert_equal 0, hidden.tickets.count
    assert_equal 0, @event.orders.count
  end

  test 'a purchase without any ticket chosen is refused' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)

    # A form with no quantity chosen sends a blank ticketForm[quantities], which blanks_to_nils turns into nil
    post_purchase(@event, buyer, quantities: '')
    assert_equal 400, last_response.status
    assert_equal OrderBuilder::NoTickets::MESSAGE, JSON.parse(last_response.body)['error']

    post_purchase(@event, buyer, quantities: { @event.ticket_types.first.id.to_s => '0' })
    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'a GoCardless purchase error names the rejected field in the email and the locked error' do
    covers 'events/payment-error-locks-event@a6adde'
    create_event(prices: [0.5])
    @organisation.set(gocardless_instant_bank_pay: true, gocardless_access_token: 'test')
    buyer = FactoryBot.create(:account)
    purchase = lambda do |error|
      emails = []
      html = EmailHelper.method(:html)
      EventPaymentMethod::GoCardlessInstantBankPay.stub :call, proc { raise error } do
        EmailHelper.stub :html, proc { |*args, **kwargs| html.call(*args, **kwargs).tap { |h| emails << h if args.first == :purchase_failed } } do
          header 'Accept', 'application/json'
          post "/e/#{@event.slug}/purchase",
               ticketForm: { quantities: { @event.ticket_types.first.id.to_s => '1' } },
               detailsForm: { payment_method: 'gocardless_instant', account: { name: buyer.name, email: buyer.email } }
        end
      end
      assert_equal 400, last_response.status
      emails
    end

    emails = purchase.call(GoCardlessPro::ValidationError.new(
                             'message' => 'Validation failed', 'request_id' => 'RQ123',
                             'errors' => [{ 'field' => 'amount', 'message' => 'must be greater than or equal to 100', 'request_pointer' => '/billing_requests/payment_request/amount' }]
                           ))
    assert_equal 1, emails.length
    assert_includes emails.first, 'Validation failed: amount must be greater than or equal to 100 (/billing_requests/payment_request/amount)'
    assert_includes emails.first, 'Request ID: RQ123'
    refute @event.reload.locked?

    emails = purchase.call(GoCardlessPro::InvalidApiUsageError.new(
                             'message' => 'Creditor <b>not</b> verified', 'request_id' => 'RQ456',
                             'errors' => [{ 'reason' => 'creditor_not_verified', 'message' => 'Creditor account not fully verified' }]
                           ))
    assert_includes emails.first, 'Creditor &lt;b&gt;not&lt;/b&gt; verified: creditor_not_verified Creditor account not fully verified'
    assert @event.reload.locked?
    assert_equal "Creditor <b>not</b> verified: creditor_not_verified Creditor account not fully verified\nRequest ID: RQ456", @event.locked_error
  end

  test 'booking onto a paid event' do
    create_event(prices: [(ticket_price = 10)], suggested_donation: 0)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', ticket_price + donation_amount)}"
  end

  test 'embedded, paying opens the payment page in a tab opened as Pay is pressed' do
    create_event(prices: [10], suggested_donation: 0)
    sign_in(@account)
    visit "/e/#{@event.slug}?ticket_form_only=1"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    assert page.has_button? 'Pay £10.00'

    payment_url = "#{ENV['BASE_URI']}/e/#{@event.slug}?cancelled=true"
    stripe_session = api_object(id: 'cs_embedded', payment_intent: 'pi_embedded', url: payment_url)
    payment_window = nil
    Stripe::Checkout::Session.stub :create, stripe_session do
      payment_window = window_opened_by { click_button 'Pay £10.00' }
      assert page.has_link?('continue to payment', href: payment_url)
    end
    within_window(payment_window) do
      assert page.has_current_path?(payment_url, url: true)
    end
  end

  test 'booking onto a paid event with a range' do
    covers 'events/price-range-slider@693b77'
    create_event(prices: ['10-100'], suggested_donation: 0)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    execute_script %{$("[name='prices[#{@event.ticket_types.first.id}]']").val(#{selected_price = 50})[0].oninput()}
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'an unknown currency is shown as text beside the price slider, not run as HTML' do
    create_event(prices: ['10-100'], suggested_donation: 0)
    @event.set(currency: '<img src=x onerror="window.pwned=1">')
    visit "/e/#{@event.slug}?prices[#{@event.ticket_types.first.id}]=50"
    assert page.has_css? '.ticket-type-price span', text: '<img src=x onerror="window.pwned=1">50'
    assert_nil evaluate_script('window.pwned')
  end

  test 'clicking disabled quantity select prompts to drag the slider' do
    create_event(prices: ['10-100'], suggested_donation: 0)
    visit "/e/#{@event.slug}"

    assert page.has_css?("select[name='quantities[#{@event.ticket_types.first.id}]'][disabled]")
    accept_alert 'Drag the slider' do
      find('.quantity-select-container').click
    end
  end

  test 'clicking disabled quantity select prompts to set a price' do
    create_event(prices: [nil], suggested_donation: 0)
    visit "/e/#{@event.slug}"

    assert page.has_css?("select[name='quantities[#{@event.ticket_types.first.id}]'][disabled]")
    accept_alert 'Set a price first' do
      find('.quantity-select-container').click
    end
  end

  test 'booking onto a paid event with a user-set price' do
    covers 'events/pay-any-amount-when-price-blank@778398'
    create_event(prices: [nil], suggested_donation: 0)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    fill_in "prices[#{@event.ticket_types.first.id}]", with: (selected_price = 50)
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'discount codes preserve quantities and prices' do
    create_event(prices: [(price0 = 10), '10-100', nil], suggested_donation: 0, questions: "q0\n[q1]\nq2")
    FactoryBot.create(:discount_code, codeable: @event, code: (code = 'DISCOUNT10'), percentage_discount: (percentage_discount = 10))
    sign_in(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types[0].id}]"
    execute_script %{$("[name='prices[#{@event.ticket_types[1].id}]']").val(#{price1 = 50})[0].oninput()}
    fill_in "prices[#{@event.ticket_types[2].id}]", with: (price2 = 50)
    execute_script %{$("[name='prices[#{@event.ticket_types[2].id}]']")[0].oninput()}
    fill_in 'donation_amount', with: (donation_amount = 5)
    fill_in 'answers[0]', with: 'a0'
    fill_in 'answers[2]', with: 'a2'
    fill_in 'discount_code', with: code
    click_button 'Apply'
    assert_equal '1', find_field("quantities[#{@event.ticket_types[0].id}]").value
    assert_equal price1.to_s, find_field("prices[#{@event.ticket_types[1].id}]").value
    assert_equal price2.to_s, find_field("prices[#{@event.ticket_types[2].id}]").value
    assert_equal donation_amount.to_s, find_field('donation_amount').value
    assert_equal 'a0', find_field('answers[0]').value
    assert_equal 'a2', find_field('answers[2]').value
    assert_equal find_field('discount_code_display', disabled: true).value, code
    assert page.has_button? "Pay £#{format('%.2f', ((price0 + price1 + price2) * (100 - percentage_discount).to_f / 100) + donation_amount)}"
  end

  test 'discount codes need at least one use, or unlimited' do
    create_event
    assert FactoryBot.build(:discount_code, codeable: @event, code: 'UNLIMITED', percentage_discount: 10).valid?
    assert FactoryBot.build(:discount_code, codeable: @event, code: 'ONCE', percentage_discount: 10, maximum_uses: 1).valid?
    discount_code = FactoryBot.build(:discount_code, codeable: @event, code: 'NEVER', percentage_discount: 10, maximum_uses: 0)
    assert !discount_code.valid?
    assert discount_code.errors[:maximum_uses].any?
  end

  test 'a used-up discount code says so to the buyer and the organiser' do
    create_event(prices: [10], suggested_donation: 0)
    discount_code = FactoryBot.create(:discount_code, codeable: @event, code: (code = 'ONCE'), percentage_discount: 100, maximum_uses: 1)
    Order.create!(event: @event, account: FactoryBot.create(:account), discount_code: discount_code, value: 0, payment_completed: true, currency: 'GBP')
    assert discount_code.exhausted?
    sign_in(@account)
    visit "/e/#{@event.slug}"
    fill_in 'discount_code', with: code
    click_button 'Apply'
    assert page.has_content? 'The code you entered has been used up'
    visit "/e/#{@event.slug}/discount_codes"
    assert page.has_css? '.badge', text: 'Used up'
  end

  test 'event with questions' do
    questions = <<~QUESTIONS.strip
      # Registration Details
      - Please fill out all fields
      Full name
      T-shirt size <XS, S, M, L, XL>
      Dietary requirements [None, Vegetarian, Vegan, Gluten-free]
      [I have read the event guidelines]
      {Arrival date}
    QUESTIONS
    create_event(prices: [0], questions: questions)
    sign_in(@account)
    visit "/e/#{@event.slug}"

    assert page.has_content?('Registration Details')
    assert page.has_content?('Please fill out all fields')

    # Fill in all question types (indices 0 and 1 are header and plain text)
    fill_in 'answers[2]', with: 'Test User'
    select 'M', from: 'answers[3]'
    find('label[for="answers-4-1"]').click # Vegetarian
    find('label[for="answers-4-2"]').click # Vegan
    find('label[for="answers-5"]').click   # Single checkbox
    fill_in 'answers[6]', with: '2024-06-01'

    click_button 'RSVP'
    assert page.has_content?('Thanks for booking')

    order = @event.orders.last
    answers = order.answers.to_h
    q = @event.questions_a

    assert_equal 'Test User', answers[q[2]]
    assert_equal 'M', answers[q[3]]
    assert_equal %w[Vegetarian Vegan], answers[q[4]]
    assert_equal '1', answers[q[5]]
    assert_equal '2024-06-01', answers[q[6]]
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Thank you page
  # ═══════════════════════════════════════════════════════════════════════════

  test 'custom thank you text is shown after booking' do
    covers 'events/thank-you-text-shown@7514dd'
    create_event(prices: [0], thank_you_text: '<p>See you at the circle</p>')
    sign_in(@account)
    visit "/e/#{@event.slug}"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert page.has_content? 'See you at the circle'
  end

  test 'a redirect URL replaces the thank you page after booking' do
    covers 'events/thank-you-redirect-url@ed8cce'
    create_event(prices: [0], redirect_url: 'https://example.com/welcome')
    order = @event.orders.create!(account: FactoryBot.create(:account), currency: @event.currency, value: 0, payment_completed: true)
    order.tickets.create!(event: @event, account: order.account, ticket_type: @event.ticket_types.first, price: 0)

    get "/e/#{@event.slug}", order_id: order.token, success: true
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Redirecting you to <a href="https://example.com/welcome">'
    assert_includes last_response.body, 'window.location = "https://example.com/welcome"'
    refute_includes last_response.body, 'If you booked'

    @event.set(redirect_url: nil)
    get "/e/#{@event.slug}", order_id: order.token, success: true
    assert_includes last_response.body, 'If you booked'
    refute_includes last_response.body, 'Redirecting you to'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Terms
  # ═══════════════════════════════════════════════════════════════════════════

  test 'falls back to organisation terms and conditions when event has none' do
    organisation = FactoryBot.build_stubbed(
      :organisation,
      terms_and_conditions: 'Org terms',
      terms_and_conditions_url: 'https://org.example/terms',
      terms_and_conditions_check_box: true
    )
    event = Event.new(organisation: organisation)

    assert_equal 'Org terms', event.terms_and_conditions_for_purchase
    assert_equal 'https://org.example/terms', event.terms_and_conditions_url_for_purchase
    assert event.terms_and_conditions_check_box_for_purchase
  end

  test 'event terms and conditions override organisation defaults' do
    organisation = FactoryBot.build_stubbed(
      :organisation,
      terms_and_conditions: 'Org terms',
      terms_and_conditions_url: 'https://org.example/terms',
      terms_and_conditions_check_box: true
    )
    event = Event.new(
      organisation: organisation,
      terms_and_conditions: 'Event terms',
      terms_and_conditions_check_box: false
    )

    assert_equal 'Event terms', event.terms_and_conditions_for_purchase
    assert_nil event.terms_and_conditions_url_for_purchase
    refute event.terms_and_conditions_check_box_for_purchase
  end

  test 'event terms and conditions URL overrides organisation terms text' do
    organisation = FactoryBot.build_stubbed(
      :organisation,
      terms_and_conditions: 'Org terms',
      terms_and_conditions_url: 'https://org.example/terms',
      terms_and_conditions_check_box: false
    )
    event = Event.new(
      organisation: organisation,
      terms_and_conditions_url: 'https://event.example/terms',
      terms_and_conditions_check_box: true
    )

    assert_nil event.terms_and_conditions_for_purchase
    assert_equal 'https://event.example/terms', event.terms_and_conditions_url_for_purchase
    assert event.terms_and_conditions_check_box_for_purchase
  end

  test 'event-level terms and conditions are shown at checkout' do
    create_organisation(terms_and_conditions: 'Organisation terms')
    create_event(prices: [0], terms_and_conditions: 'Event terms')
    visit "/e/#{@event.slug}"
    assert_equal 'Event terms', find('textarea[readonly]').value
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Ticket booking subscriptions
  # ═══════════════════════════════════════════════════════════════════════════

  test 'new user booking ticket to free event gets subscribed to org, activity, and local_group' do
    create_full_event_hierarchy(event_options: { prices: [0], opt_in_organisation: true })
    buyer = FactoryBot.create(:account)

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    assert page.has_content?("Signed in as #{buyer.name}")
    assert page.has_content? 'Register for free'

    # Click the label to check the box, as people do
    find('label[for="account_opt_in_organisation"]').click

    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'

    assert_associated(@organisation, buyer, :organisationships)
    assert_associated(@activity, buyer, :activityships)
    assert_associated(@local_group, buyer, :local_groupships)

    assert_equal false, @organisation.organisationships.find_by(account: buyer).unsubscribed
    assert_equal false, @activity.activityships.find_by(account: buyer).unsubscribed
    assert_equal false, @local_group.local_groupships.find_by(account: buyer).unsubscribed
  end

  test 'collect_location with postcode in local_group area subscribes user to local_group' do
    covers 'organisations/followers-join-local-groups@336869'
    create_organisation(collect_location: true)
    # Local group with Gamla Stan polygon (from factory)
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    # Event WITHOUT local_group - we want to test geo-based local_groupship creation
    create_event(prices: [0], opt_in_organisation: true)

    visit "/e/#{@event.slug}"
    assert page.has_content? 'Register for free'

    # New users (not logged in) should see postcode and country fields
    assert page.has_field?('account_postcode'), 'Postcode field should be visible'
    assert page.has_field?('account_country'), 'Country field should be visible'

    # Fill in the form with a Gamla Stan postcode (111 28 is in the polygon)
    fill_in 'account_name', with: 'Stockholm User'
    fill_in 'account_email', with: 'gamlastan@example.com'
    fill_in 'account_postcode', with: '111 28'
    select 'Sweden', from: 'account_country'

    find('label[for="account_opt_in_organisation"]').click

    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'

    # Verify account was created with location, but geocoded in the background rather than during checkout
    new_account = Account.find_by(email: 'gamlastan@example.com')
    assert new_account.present?, 'Account should be created'
    assert new_account.location.include?('111 28'), "Location should include postcode, got: #{new_account.location}"
    assert_nil new_account.coordinates, 'Checkout should leave geocoding to a background job'

    organisationship = @organisation.organisationships.find_by(account: new_account)
    assert organisationship, 'User should be subscribed to organisation'
    assert_nil local_group.local_groupships.find_by(account: new_account)

    assert Delayed::Job.and(handler: /geocode_location!/).exists?, 'Checkout should queue geocoding'
    new_account.geocode_location!
    assert new_account.reload.coordinates.present?, 'Account should have coordinates from geocoding'

    # Verify user is auto-subscribed to local_group based on their geocoded location
    # (geocode_location! creates the local_groupship the organisationship couldn't, as the account had no coordinates)
    local_groupship = local_group.local_groupships.find_by(account: new_account)
    assert local_groupship, 'User with coordinates in Gamla Stan should be subscribed to local_group'
  end

  test 'existing unsubscribed user booking ticket to free event gets resubscribed' do
    create_full_event_hierarchy(event_options: { prices: [0], opt_in_organisation: true })

    # Create an existing account that's unsubscribed from org, activity, and local_group
    buyer = FactoryBot.create(:account)
    @organisation.organisationships.find_or_create_by(account: buyer).set_unsubscribed!(true)
    @activity.activityships.find_or_create_by(account: buyer).set(unsubscribed: true)
    @local_group.local_groupships.find_or_create_by(account: buyer).set(unsubscribed: true)

    # Book ticket with opt-in (existing members have hidden field set to 1 automatically)
    sign_in(buyer)
    visit "/e/#{@event.slug}"
    assert page.has_content?("Signed in as #{buyer.name}")
    assert page.has_content? 'Register for free'

    # For existing members, opt_in_organisation is automatically set via hidden field

    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'

    assert_equal false, @organisation.organisationships.find_by(account: buyer).unsubscribed
    assert_equal false, @activity.activityships.find_by(account: buyer).unsubscribed
    assert_equal false, @local_group.local_groupships.find_by(account: buyer).unsubscribed
  end

  test "booking with the opt-in resubscribes to a co-host without a new co-host's membership undoing it" do
    create_event(prices: [0], opt_in_organisation: true)
    # The opt-in goes through the host, then the co-hosts in order: one the buyer unsubscribed from, then one they're new to
    unsubscribed_cohost = FactoryBot.create(:organisation)
    new_cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: unsubscribed_cohost)
    @event.cohostships.create!(organisation: new_cohost)
    buyer = FactoryBot.create(:account)
    unsubscribed_cohost.organisationships.create!(account: buyer, unsubscribed: true, skip_welcome: true)

    sign_in(buyer)
    visit "/e/#{@event.slug}"
    assert page.has_content?("Signed in as #{buyer.name}")
    find('label[for="account_opt_in_organisation"]').click
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'

    organisations = [@organisation, unsubscribed_cohost, new_cohost]
    organisations.each { |organisation| assert_equal false, organisation.organisationships.find_by(account: buyer).unsubscribed }
    buyer.reload
    assert_equal organisations.map(&:id).sort, buyer.subscribed_organisation_ids_cache.sort
    assert_empty buyer.unsubscribed_organisation_ids_cache
    assert_equal organisations.map(&:id).sort, buyer.organisation_ids_cache.sort
  end

  test 'a mistyped email domain is booked after confirming' do
    create_event(prices: [0])

    visit "/e/#{@event.slug}"
    fill_in 'account_name', with: 'Typo User'
    fill_in 'account_email', with: 'someone@gmial.com'
    message = accept_confirm { click_button 'RSVP' }
    assert_includes message, 'You entered your email address as someone@gmial.com'
    assert page.has_content? 'Thanks for booking'
    assert Account.find_by(email: 'someone@gmial.com')
  end

  test 'a mistyped email domain goes back to the form after cancelling' do
    create_event(prices: [0])

    visit "/e/#{@event.slug}"
    fill_in 'account_name', with: 'Typo User'
    fill_in 'account_email', with: 'someone@gmial.com'
    dismiss_confirm { click_button 'RSVP' }
    assert page.has_no_content? 'Thanks for booking'
    assert_nil Account.find_by(email: 'someone@gmial.com')

    fill_in 'account_email', with: 'someone@gmail.com'
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert Account.find_by(email: 'someone@gmail.com')
  end

  test 'embedded, a mistyped email domain is booked after pressing again' do
    create_event(prices: [0])

    visit "/e/#{@event.slug}?ticket_form_only=1"
    fill_in 'account_name', with: 'Typo User'
    fill_in 'account_email', with: 'someone@gmial.com'
    click_button 'RSVP'
    assert page.has_content? 'You entered your email address as someone@gmial.com, which looks mistyped. Press the button again to book with this email address.'
    assert_nil Account.find_by(email: 'someone@gmial.com')

    click_button 'RSVP'
    assert page.has_current_path?(/success=true/, url: true)
    assert Account.find_by(email: 'someone@gmial.com')
  end

  test "signed in, an email that looks mistyped is booked without asking, as it is the account's own" do
    create_event(prices: [0])
    signed_in = FactoryBot.create(:account, email: 'other@hotmail.con')

    sign_in(signed_in)
    visit "/e/#{@event.slug}"
    refuse_confirmations
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert @event.orders.find_by(account: signed_in)
  end

  test "the checkout form shows why a booking was refused, and books once it's fixed" do
    create_event(prices: [0], terms_and_conditions: 'Be kind', terms_and_conditions_check_box: true)

    visit "/e/#{@event.slug}"
    fill_in 'account_name', with: 'Terms User'
    fill_in 'account_email', with: 'terms@example.com'
    message = accept_alert { click_button 'RSVP' }
    assert_equal 'You must agree to the terms and conditions.', message
    assert_equal 0, @event.orders.count

    find('label[for="accepted-terms"]').click
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Purchase access
  # ═══════════════════════════════════════════════════════════════════════════

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

  # OrderBuilder checks these, and the checkout form shows its messages. These post without the form, as a request
  # needn't come from it

  def post_checkout(ticket_form: {}, details_form: {})
    @buyer ||= FactoryBot.create(:account)
    header 'Accept', 'application/json'
    post "/e/#{@event.slug}/purchase",
         ticketForm: { quantities: { @event.ticket_types.first.id.to_s => '1' } }.merge(ticket_form),
         detailsForm: { payment_method: 'stripe', account: { name: @buyer.name, email: @buyer.email } }.merge(details_form)
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

  # ═══════════════════════════════════════════════════════════════════════════
  # Duplicate ticket warning
  # ═══════════════════════════════════════════════════════════════════════════

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

  # ═══════════════════════════════════════════════════════════════════════════
  # Credit
  # ═══════════════════════════════════════════════════════════════════════════

  def grant_credit(account, amount:)
    organisationship = @organisation.organisationships.find_or_create_by(account: account)
    organisationship.creditings.create!(account: @account, amount: amount, currency: @event.currency)
  end

  test 'credit pays for tickets, not a donation to Dandelion' do
    create_event(prices: [10])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert @event.reload.donations_to_dandelion?
    @buyer = FactoryBot.create(:account)
    grant_credit(@buyer, amount: 15)
    sign_in_with_rack(@buyer)

    # Credit covers the tickets, so the order completes with no payment, which a donation to Dandelion would need
    post_checkout(ticket_form: { donation_amount: '1' })
    assert_equal 200, last_response.status
    order = @event.orders.find_by(account: @buyer)
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

  test 'checkout takes credit off the tickets, not a donation to Dandelion, when the tickets are free' do
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

  test 'ticket_form_only does not render the purchase form when the buyer cannot purchase' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })

    get "/e/#{@event.slug}", ticket_form_only: 1

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'id="select-tickets"'
    assert_includes last_response.body, 'monthly donor'
  end
end
