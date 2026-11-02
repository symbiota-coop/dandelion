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

    purchase.call(hidden.token)
    assert_equal 200, last_response.status
    assert_equal 1, hidden.tickets.count

    hidden.unset(:token)
    header 'Accept', 'application/json'
    post "/e/#{@event.slug}/purchase",
         confirmed_duplicate: '1',
         ticketForm: { quantities: { hidden.id.to_s => '1' }, ticket_type_id: hidden.id.to_s },
         detailsForm: { payment_method: 'rsvp', account: { name: buyer.name, email: buyer.email } }
    assert_equal 200, last_response.status
    assert_equal 2, hidden.tickets.count
  end

  test 'a GoCardless purchase error names the rejected field in the email and the locked error' do
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
    create_event(prices: ['10-100'], suggested_donation: 0)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    execute_script %{$("[name='prices[#{@event.ticket_types.first.id}]']").val(#{selected_price = 50})[0].oninput()}
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
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
    create_event(prices: [0], thank_you_text: '<p>See you at the circle</p>')
    sign_in(@account)
    visit "/e/#{@event.slug}"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
    assert page.has_content? 'See you at the circle'
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
    create_full_event_hierarchy(event_options: { prices: [0], locked: true })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)

    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'purchase is allowed when the event is locked and the buyer is an event admin' do
    create_full_event_hierarchy(event_options: { prices: [0], locked: true })

    sign_in_with_rack(@account)
    post_purchase(@event, @account)

    assert_equal 200, last_response.status
    assert @event.orders.find_by(account: @account)
  end

  test 'purchase is forbidden when monthly_donors_only and the buyer is not a signed-in donor' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    assert_equal 403, last_response.status

    sign_in_with_rack(buyer)
    post_purchase(@event, buyer)
    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'purchase is allowed when monthly_donors_only and the buyer is a signed-in donor' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })
    buyer = FactoryBot.create(:account)
    FactoryBot.create(:organisationship, organisation: @organisation, account: buyer, monthly_donation_method: 'Other', monthly_donation_amount: 1)

    sign_in_with_rack(buyer)
    post_purchase(@event, buyer)

    assert_equal 200, last_response.status
    assert @event.orders.find_by(account: buyer)
  end

  test 'purchase is forbidden when the activity is closed and the buyer is not a member' do
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

  test 'purchase is allowed when the activity is closed and the buyer is a signed-in member' do
    create_full_event_hierarchy(event_options: { prices: [0] })
    @activity.set(privacy: 'closed')
    buyer = FactoryBot.create(:account)
    @activity.activityships.create!(account: buyer)

    sign_in_with_rack(buyer)
    post_purchase(@event, buyer)

    assert_equal 200, last_response.status
    assert @event.orders.find_by(account: buyer)
  end

  test 'purchase remains allowed for an open unlocked event' do
    create_full_event_hierarchy(event_options: { prices: [0] })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)

    assert_equal 200, last_response.status
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

    Stripe::Checkout::Session.stub(:create, api_object(id: 'cs_test', payment_intent: 'pi_test', url: 'https://checkout.stripe.com/test')) do
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

  def with_stubbed_stripe_session(&)
    Stripe::Checkout::Session.stub(:create, api_object(id: 'cs_test', payment_intent: 'pi_test', url: 'https://checkout.stripe.com/test'), &)
  end

  test 'purchase needs the terms accepted when the event asks' do
    create_event(prices: [0], terms_and_conditions: 'Be kind', terms_and_conditions_check_box: true)

    post_checkout(details_form: { payment_method: 'rsvp' })
    assert_equal 400, last_response.status
    assert_equal 'You must agree to the terms and conditions.', JSON.parse(last_response.body)['error']
    assert_equal 0, @event.orders.count

    post_checkout(details_form: { payment_method: 'rsvp', accepted_terms: '1' })
    assert_equal 200, last_response.status
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

  test "purchase refuses a donation the event doesn't take" do
    create_event(prices: [10])
    @event.set(suggested_donation: nil)

    post_checkout(ticket_form: { donation_amount: '5' })

    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'purchase is allowed up to max_quantity_per_transaction' do
    create_event(prices: [0])
    @event.ticket_types.first.set(quantity: 10, max_quantity_per_transaction: 2)
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer, quantity: 2)

    assert_equal 200, last_response.status
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

  test 'purchase warns when the account already holds a ticket' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    assert_equal 200, last_response.status

    post_purchase(@event, buyer)
    assert_equal 409, last_response.status
    assert JSON.parse(last_response.body)['duplicate']
    assert_equal 1, @event.orders.count
  end

  test 'purchase proceeds when confirmed_duplicate is set' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    post_purchase(@event, buyer, confirmed_duplicate: true)

    assert_equal 200, last_response.status
    assert_equal 2, @event.orders.count
  end

  test 'purchase warns when a ticket was already ordered for that email' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)

    post_purchase(@event, FactoryBot.create(:account))
    @event.tickets.last.set(email: buyer.email)

    post_purchase(@event, buyer)
    assert_equal 409, last_response.status
  end

  test "purchase does not warn when the account's earlier ticket was reassigned to someone else" do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    @event.tickets.last.set(email: 'friend@example.com')

    post_purchase(@event, buyer)
    assert_equal 200, last_response.status
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Credit
  # ═══════════════════════════════════════════════════════════════════════════

  def grant_credit(account, amount:)
    organisationship = @organisation.organisationships.find_or_create_by(account: account)
    organisationship.creditings.create!(account: @account, amount: amount, currency: @event.currency)
  end

  test 'purchase applies credit when the signed-in buyer is the order account' do
    create_event(prices: [10], suggested_donation: 0)
    buyer = FactoryBot.create(:account)
    grant_credit(buyer, amount: 10)

    sign_in_with_rack(buyer)
    post_purchase(@event, buyer)

    assert_equal 200, last_response.status
    order = @event.orders.find_by(account: buyer)
    assert_equal 10, order.credit_applied
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
