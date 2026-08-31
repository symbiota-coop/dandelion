require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventBookingsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def post_purchase(event, account)
    ticket_type = event.ticket_types.first
    header 'Accept', 'application/json'
    post "/events/#{event.id}/purchase",
         ticketForm: { quantities: { ticket_type.id.to_s => '1' } },
         detailsForm: {
           payment_method: 'rsvp',
           account: { name: account.name, email: account.email }
         }
  end

  test 'booking onto a paid event' do
    create_event(prices: [(ticket_price = 10)], suggested_donation: 0)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', ticket_price + donation_amount)}"
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
    assert_equal find_field("quantities[#{@event.ticket_types[0].id}]").value, '1'
    assert_equal find_field("prices[#{@event.ticket_types[1].id}]").value, price1.to_s
    assert_equal find_field("prices[#{@event.ticket_types[2].id}]").value, price2.to_s
    assert_equal find_field('donation_amount').value, donation_amount.to_s
    assert_equal find_field('answers[0]').value, 'a0'
    assert_equal find_field('answers[2]').value, 'a2'
    assert_equal find_field('discount_code_display', disabled: true).value, code
    assert page.has_button? "Pay £#{format('%.2f', ((price0 + price1 + price2) * (100 - percentage_discount).to_f / 100) + donation_amount)}"
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

    # Verify header and plain text are displayed
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
    assert page.has_content? 'Register for free'

    # Click the label to check the custom-styled checkbox (actual input is hidden via CSS)
    find('label[for="account_opt_in_organisation"]').click

    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'

    # Verify account is associated and subscribed
    assert_associated(@organisation, buyer, :organisationships)
    assert_associated(@activity, buyer, :activityships)
    assert_associated(@local_group, buyer, :local_groupships)

    # Verify they're subscribed (not unsubscribed)
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

    # Check opt-in checkbox
    find('label[for="account_opt_in_organisation"]').click

    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'

    # Verify account was created with location and coordinates
    new_account = Account.find_by(email: 'gamlastan@example.com')
    assert new_account.present?, 'Account should be created'
    assert new_account.location.include?('111 28'), "Location should include postcode, got: #{new_account.location}"
    assert new_account.coordinates.present?, 'Account should have coordinates from geocoding'

    # Check organisationship was created
    organisationship = @organisation.organisationships.find_by(account: new_account)
    assert organisationship, 'User should be subscribed to organisation'

    # Verify user is auto-subscribed to local_group based on their geocoded location
    # (organisationship.after_create creates local_groupship when account coordinates are within polygon)
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
    assert page.has_content? 'Register for free'

    # For existing members, opt_in_organisation is automatically set via hidden field

    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'

    # Verify they're resubscribed
    assert_equal false, @organisation.organisationships.find_by(account: buyer).unsubscribed
    assert_equal false, @activity.activityships.find_by(account: buyer).unsubscribed
    assert_equal false, @local_group.local_groupships.find_by(account: buyer).unsubscribed
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

  # ═══════════════════════════════════════════════════════════════════════════
  # Credit
  # ═══════════════════════════════════════════════════════════════════════════

  def grant_credit(account, amount:)
    organisationship = @organisation.organisationships.find_or_create_by(account: account)
    organisationship.creditings.create!(account: @account, amount: amount, currency: @event.currency)
  end

  test "purchase applies credit when the signed-in buyer is the order account" do
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
