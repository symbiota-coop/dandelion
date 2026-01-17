require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating an event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.build_stubbed(:event)
    @ticket_type = FactoryBot.build_stubbed(:ticket_type)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_in 'Event title*', with: @event.name
    execute_script %{$('#event_start_time').val('#{@event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{@event.end_time.to_fs(:db_local)}')}
    fill_in 'Location*', with: @event.location
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: @ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: @ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    assert page.has_content? 'Add to calendar'
  end

  test 'creating an event with a range' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.build_stubbed(:event)
    @ticket_type = FactoryBot.build_stubbed(:ticket_type, price_or_range: '10-100')
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_in 'Event title*', with: @event.name
    execute_script %{$('#event_start_time').val('#{@event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{@event.end_time.to_fs(:db_local)}')}
    fill_in 'Location*', with: @event.location
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: @ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: @ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    assert page.has_content? 'Drag the slider'
  end

  test 'creating an event from /events' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    login_as(@account)
    visit '/events'
    click_link 'Create an event'
    select @organisation.name, from: 'organisation_id'
    assert page.has_content? 'Event title*'
  end

  test 'editing an event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [0])
    login_as(@account)
    visit "/e/#{@event.slug}/edit"
    fill_in 'Event title*', with: (name = FactoryBot.build_stubbed(:event).name)
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert page.has_content? name
  end

  test 'booking onto a free event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [0])
    login_as(@account)
    visit "/e/#{@event.slug}"
    assert page.has_content? 'Register for free'
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking!'
  end

  test 'booking onto a paid event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [(ticket_price = 10)], suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', ticket_price + donation_amount)}"
  end

  test 'booking onto a paid event with a range' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: ['10-100'], suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    execute_script %{$("[name='prices[#{@event.ticket_types.first.id}]']").val(#{selected_price = 50})[0].oninput()}
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'booking onto a paid event with a user-set price' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [nil], suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    fill_in "prices[#{@event.ticket_types.first.id}]", with: (selected_price = 50)
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'discount codes preserve quantities and prices' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [(price_0 = 10), '10-100', nil], suggested_donation: 0, questions: "q0\n[q1]\nq2")
    @discount_code = FactoryBot.create(:discount_code, codeable: @event, code: (code = 'DISCOUNT10'), percentage_discount: (percentage_discount = 10))
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types[0].id}]"
    execute_script %{$("[name='prices[#{@event.ticket_types[1].id}]']").val(#{price_1 = 50})[0].oninput()}
    fill_in "prices[#{@event.ticket_types[2].id}]", with: (price_2 = 50)
    execute_script %{$("[name='prices[#{@event.ticket_types[2].id}]']")[0].oninput()}
    fill_in 'donation_amount', with: (donation_amount = 5)
    fill_in 'answers[0]', with: 'a0'
    fill_in 'answers[2]', with: 'a2'
    fill_in 'discount_code', with: code
    click_button 'Apply'
    assert_equal find_field("quantities[#{@event.ticket_types[0].id}]").value, '1'
    assert_equal find_field("prices[#{@event.ticket_types[1].id}]").value, price_1.to_s
    assert_equal find_field("prices[#{@event.ticket_types[2].id}]").value, price_2.to_s
    assert_equal find_field('donation_amount').value, donation_amount.to_s
    assert_equal find_field('answers[0]').value, 'a0'
    assert_equal find_field('answers[2]').value, 'a2'
    assert_equal find_field('discount_code_display', disabled: true).value, code
    assert page.has_button? "Pay £#{format('%.2f', ((price_0 + price_1 + price_2) * (100 - percentage_discount).to_f / 100) + donation_amount)}"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Ticket Booking Subscriptions
  # ═══════════════════════════════════════════════════════════════════════════

  test 'new user booking ticket to free event gets subscribed to org, activity, and local_group' do
    create_full_event_hierarchy(event_options: { prices: [0], opt_in_organisation: true })
    @account = FactoryBot.create(:account)

    login_as(@account)
    visit "/e/#{@event.slug}"
    assert page.has_content? 'Register for free'

    # Click the label to check the custom-styled checkbox (actual input is hidden via CSS)
    find('label[for="account_opt_in_organisation"]').click

    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking!'

    # Verify account is associated and subscribed
    assert_associated(@organisation, @account, :organisationships)
    assert_associated(@activity, @account, :activityships)
    assert_associated(@local_group, @account, :local_groupships)

    # Verify they're subscribed (not unsubscribed)
    assert_equal false, @organisation.organisationships.find_by(account: @account).unsubscribed
    assert_equal false, @activity.activityships.find_by(account: @account).unsubscribed
    assert_equal false, @local_group.local_groupships.find_by(account: @account).unsubscribed
  end

  test 'collect_location with postcode in local_group area subscribes user to local_group' do
    @org_account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @org_account, collect_location: true)
    # Local group with Gamla Stan polygon (from factory)
    @local_group = FactoryBot.create(:local_group, organisation: @organisation, account: @org_account)
    # Event WITHOUT local_group - we want to test geo-based local_groupship creation
    @event = FactoryBot.create(:event,
                               organisation: @organisation,
                               account: @org_account,
                               last_saved_by: @org_account,
                               prices: [0],
                               opt_in_organisation: true)

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
    assert page.has_content? 'Thanks for booking!'

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
    local_groupship = @local_group.local_groupships.find_by(account: new_account)
    assert local_groupship, 'User with coordinates in Gamla Stan should be subscribed to local_group'
  end

  test 'existing unsubscribed user booking ticket to free event gets resubscribed' do
    create_full_event_hierarchy(event_options: { prices: [0], opt_in_organisation: true })

    # Create an existing account that's unsubscribed from org, activity, and local_group
    @account = FactoryBot.create(:account)
    @organisation.organisationships.find_or_create_by(account: @account).set_unsubscribed!(true)
    @activity.activityships.find_or_create_by(account: @account).set(unsubscribed: true)
    @local_group.local_groupships.find_or_create_by(account: @account).set(unsubscribed: true)

    # Book ticket with opt-in (existing members have hidden field set to 1 automatically)
    login_as(@account)
    visit "/e/#{@event.slug}"
    assert page.has_content? 'Register for free'

    # For existing members, opt_in_organisation is automatically set via hidden field

    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking!'

    # Verify they're resubscribed
    assert_equal false, @organisation.organisationships.find_by(account: @account).unsubscribed
    assert_equal false, @activity.activityships.find_by(account: @account).unsubscribed
    assert_equal false, @local_group.local_groupships.find_by(account: @account).unsubscribed
  end

  test 'event with questions' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    questions = <<~QUESTIONS.strip
      # Registration Details
      - Please fill out all fields
      Full name
      T-shirt size <XS, S, M, L, XL>
      Dietary requirements [None, Vegetarian, Vegan, Gluten-free]
      [I have read the event guidelines]
      {Arrival date}
    QUESTIONS
    @event = FactoryBot.create(:event,
                               organisation: @organisation,
                               account: @account,
                               last_saved_by: @account,
                               prices: [0],
                               questions: questions)
    login_as(@account)
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
end
