require_relative '../test_config'
require_relative '../helpers/bookings_helpers'

# Booking onto an event: the checkout form, discount codes, questions, terms and subscriptions
class EventBookingsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include BookingsHelpers

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
    covers_route 'POST /e/:slug/purchase'
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

  test "a paid event's checkout asks for the ticket price and the donation" do
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

  test 'with a price range, the checkout asks for the price chosen on the slider and the donation' do
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

  test 'with a price left blank, the checkout asks for the price entered and the donation' do
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
    covers_route 'GET /e/:slug'
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

  test 'anyone not signed in as an email can book for it only so many times an hour' do
    covers 'events/guest-bookings-limited-per-email@3b708e'
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    limit = RecipientLimit::LIMITS[:guest_booking][:limit]

    limit.times do
      post_purchase(@event, buyer, confirmed_duplicate: true)
      assert_equal 200, last_response.status
    end
    post_purchase(@event, buyer, confirmed_duplicate: true)
    assert_equal 429, last_response.status
    assert_equal OrderBuilder::TooManyBookings::MESSAGE, JSON.parse(last_response.body)['error']
    assert_equal limit, @event.orders.count
  end

  test 'a duplicate booking confirmed after its warning counts once towards the limit' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    post_purchase(@event, buyer)
    assert_equal 200, last_response.status

    (RecipientLimit::LIMITS[:guest_booking][:limit] - 1).times do
      post_purchase(@event, buyer)
      assert_equal 409, last_response.status
      post_purchase(@event, buyer, confirmed_duplicate: true)
      assert_equal 200, last_response.status
    end
    assert_equal RecipientLimit::LIMITS[:guest_booking][:limit], @event.orders.count
  end

  test 'someone signed in as the buyer can book beyond the limit' do
    covers 'events/own-bookings-not-limited@cdc1bb'
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    sign_in_with_rack(buyer)

    (RecipientLimit::LIMITS[:guest_booking][:limit] + 1).times do
      post_purchase(@event, buyer, confirmed_duplicate: true)
      assert_equal 200, last_response.status
    end
  end

  test 'someone signed in as the buyer before confirming its email is limited' do
    covers 'events/own-bookings-not-limited@cdc1bb'
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    sign_in_with_rack(buyer)
    # As after signing up with an address, which signs in before the email is confirmed
    buyer.set(email_confirmed: false)

    RecipientLimit::LIMITS[:guest_booking][:limit].times do
      post_purchase(@event, buyer, confirmed_duplicate: true)
      assert_equal 200, last_response.status
    end
    post_purchase(@event, buyer, confirmed_duplicate: true)
    assert_equal 429, last_response.status
  end
end
