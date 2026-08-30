require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def fill_event_create_form(event, ticket_type)
    fill_in 'Event title*', with: event.name
    execute_script %{$('#event_start_time').val('#{event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{event.end_time.to_fs(:db_local)}')}
    fill_in 'Location', with: event.location if event.location
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: ticket_type.quantity
    click_link 'Everything else'
  end

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

  def add_member(org, **attrs)
    account = FactoryBot.create(:account)
    account.organisationships.create!(organisation: org, unsubscribed: false, **attrs)
    account
  end

  def add_event_manager(org)
    add_member(org, event_manager: true)
  end

  def create_evergreen_event(**attrs)
    create_event(:evergreen, prices: [0], **attrs)
  end

  def create_evergreen_order
    @attendee = FactoryBot.create(:account)
    create_evergreen_event
    @order = @event.orders.create!(account: @attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'Manual test order')
  end

  test 'creating an event' do
    create_organisation
    event = FactoryBot.build_stubbed(:event)
    ticket_type = FactoryBot.build_stubbed(:ticket_type)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_event_create_form(event, ticket_type)
    click_button 'Create event'
    assert page.has_content? 'Add to calendar'
  end

  test 'creating an event with a range' do
    create_organisation
    event = FactoryBot.build_stubbed(:event)
    ticket_type = FactoryBot.build_stubbed(:ticket_type, price_or_range: '10-100')
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_event_create_form(event, ticket_type)
    click_button 'Create event'
    assert page.has_content? 'Drag the slider'
  end

  test 'editing an event' do
    create_event(prices: [0])
    login_as(@account)
    visit "/e/#{@event.slug}/edit"
    fill_in 'Event title*', with: (name = FactoryBot.build_stubbed(:event).name)
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert page.has_content? name
  end

  test 'reminder is due when its send time falls within the next hour' do
    now = Time.utc(2026, 3, 13, 8, 55, 0)
    event = Event.new(start_time: Time.utc(2026, 3, 13, 10, 0, 0), reminder_hours_before: 1)

    assert event.reminder_due_within?(1.hour, now)
  end

  test 'reminder is not due once the event has started' do
    now = Time.utc(2026, 3, 13, 10, 0, 0)
    event = Event.new(start_time: now - 5.minutes, reminder_hours_before: 1)

    refute event.reminder_due_within?(1.hour, now)
  end

  test 'feedback request is due when its send time falls within the next hour' do
    now = Time.utc(2026, 3, 13, 10, 55, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0),
      feedback_hours_after: 1
    )

    assert event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request with blank hours is due at event end' do
    now = Time.utc(2026, 3, 13, 9, 55, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0)
    )

    assert event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request is not sent once it has already been sent' do
    now = Time.utc(2026, 3, 13, 10, 55, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0),
      feedback_hours_after: 1,
      sent_feedback_requests_at: Time.utc(2026, 3, 13, 10, 0, 0)
    )

    refute event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request bulk task does not reschedule very old pending sends' do
    now = Time.utc(2026, 5, 17, 12, 0, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0),
      feedback_hours_after: 0
    )

    refute event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request delay cannot exceed 30 days' do
    event = Event.new(feedback_hours_after: Event::MAX_FEEDBACK_HOURS_AFTER + 1)
    event.valid?

    assert_includes event.errors[:feedback_hours_after], "cannot be more than #{Event::MAX_FEEDBACK_HOURS_AFTER}"
  end

  test 'booking onto a paid event' do
    create_event(prices: [(ticket_price = 10)], suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', ticket_price + donation_amount)}"
  end

  test 'booking onto a paid event with a range' do
    create_event(prices: ['10-100'], suggested_donation: 0)
    login_as(@account)
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
    login_as(@account)
    visit "/e/#{@event.slug}"
    fill_in "prices[#{@event.ticket_types.first.id}]", with: (selected_price = 50)
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'discount codes preserve quantities and prices' do
    create_event(prices: [(price0 = 10), '10-100', nil], suggested_donation: 0, questions: "q0\n[q1]\nq2")
    FactoryBot.create(:discount_code, codeable: @event, code: (code = 'DISCOUNT10'), percentage_discount: (percentage_discount = 10))
    login_as(@account)
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

  # ═══════════════════════════════════════════════════════════════════════════
  # Ticket Booking Subscriptions
  # ═══════════════════════════════════════════════════════════════════════════

  test 'new user booking ticket to free event gets subscribed to org, activity, and local_group' do
    create_full_event_hierarchy(event_options: { prices: [0], opt_in_organisation: true })
    buyer = FactoryBot.create(:account)

    login_as(buyer)
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
    login_as(buyer)
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

  test 'public event submission creates draft and notifies admins' do
    Delayed::Job.delete_all if defined?(Delayed::Job)
    create_organisation(allow_event_submissions: true)
    submitter = FactoryBot.create(:account)
    event = FactoryBot.build_stubbed(:event)

    login_as(submitter)
    visit "/o/#{@organisation.slug}/events"
    assert page.has_link?('Submit an event for review'), 'Non-admin should see submit button when org allows public submissions'

    click_link 'Submit an event for review'
    fill_in 'Event title*', with: event.name
    execute_script %{$('#event_start_time').val('#{event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{event.end_time.to_fs(:db_local)}')}
    click_link 'Everything else'
    click_button 'Create event'

    created_event = Event.find_by(name: event.name)
    assert created_event, 'Event should be created'
    assert created_event.locked?, 'Event should be locked when submitted by non-admin'
    assert_equal submitter.id, created_event.account_id, 'Event should be attributed to submitter'
    assert_equal 0, created_event.notifications.and(type: 'created_event').count, 'Locked submission should not create a public event notification'
    assert_equal 1, Delayed::Job.and(handler: /send_public_submission_notification/).count, 'Submission email should be queued'

    visit "/e/#{created_event.slug}/edit"
    assert page.has_content?('Event title'), 'Submitter should be able to access edit page'
    refute page.has_css?('label[for="event_locked"]'), 'Submitter should not see locked checkbox'
    assert page.has_content?('submitted for review'), 'Submitter should see unlock message'
  end

  test 'event admin can lock but only lock admin can unlock' do
    create_organisation(allow_event_submissions: true)
    org_admin = @account
    coordinator = FactoryBot.create(:account)
    create_event(coordinator: coordinator, locked: false, prices: [0])

    assert Event.admin?(@event, coordinator), 'Coordinator should be event admin'
    refute Event.lock_admin?(@event, coordinator), 'Coordinator should not be lock admin'

    # Event admin (coordinator) can lock an unlocked event
    login_as(coordinator)
    visit "/e/#{@event.slug}/edit"
    assert page.has_css?('label[for="event_locked"]'), 'Event admin should see locked checkbox when event is unlocked'
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    assert @event.reload.locked?, 'Event should be locked after event admin checks the box'

    # Event admin (coordinator) cannot unlock - checkbox should be hidden
    visit "/e/#{@event.slug}/edit"
    refute page.has_css?('label[for="event_locked"]'), 'Event admin should not see locked checkbox when event is locked (cannot unlock)'
    assert page.has_content?('submitted for review'), 'Non-lock-admin should see unlock message'

    # Lock admin (org admin) can unlock
    login_as(org_admin)
    visit "/e/#{@event.slug}/edit"
    assert page.has_css?('label[for="event_locked"]'), 'Lock admin should see locked checkbox'
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    refute @event.reload.locked?, 'Event should be unlocked after lock admin unchecks the box'
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

  test 'organisation_id and account_id cannot be reassigned on update' do
    create_event(prices: [0])
    assert_cannot_reassign_organisation_or_account(@event)
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

  test 'redirect_url must be a valid http or https URL' do
    create_organisation
    event = FactoryBot.build(:event, organisation: @organisation)

    event.redirect_url = 'https://example.com/thanks'
    assert event.valid?

    event.redirect_url = 'http://example.com/thanks'
    assert event.valid?

    event.redirect_url = 'javascript:alert(document.cookie)'
    refute event.valid?
    assert_includes event.errors[:redirect_url], 'must be a valid http or https URL'

    event.redirect_url = 'data:text/html,<script>alert(1)</script>'
    refute event.valid?

    event.redirect_url = nil
    assert event.valid?
  end

  test 'safe_redirect_url ignores stored javascript URLs' do
    create_event
    @event.set(redirect_url: 'javascript:alert(1)')

    assert_nil @event.reload.safe_redirect_url
    assert_equal 'https://example.org/thanks', @event.tap { |e| e.redirect_url = 'https://example.org/thanks' }.safe_redirect_url
  end

  test 'slug uniqueness includes deleted events' do
    create_event
    slug = @event.slug
    @event.destroy

    assert_nil Event.find_by(slug: slug)
    assert Event.unscoped.and(slug: slug).exists?

    clash = FactoryBot.build(:event, organisation: @organisation, slug: slug)
    refute clash.valid?
    assert clash.errors[:slug].any?
  end

  test 'duplicating an event skips slugs belonging to deleted events' do
    create_event(as: :event1, prices: [0])
    create_event(as: :event2, slug: 'a0aaa')
    @event2.destroy

    candidates = ['a0aaa', 'z9zzz']
    Event.stub :slug_candidate, -> { candidates.shift } do
      duplicate = @event1.duplicate!(@account)
      assert duplicate.persisted?
      assert_equal 'z9zzz', duplicate.slug
    end
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

    rack_login_as(@account)
    post_purchase(@event, @account)

    assert_equal 200, last_response.status
    assert @event.orders.find_by(account: @account)
  end

  test 'purchase is forbidden when monthly_donors_only and the buyer is not a signed-in donor' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    assert_equal 403, last_response.status

    rack_login_as(buyer)
    post_purchase(@event, buyer)
    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'purchase is allowed when monthly_donors_only and the buyer is a signed-in donor' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })
    buyer = FactoryBot.create(:account)
    FactoryBot.create(:organisationship, organisation: @organisation, account: buyer, monthly_donation_method: 'Other', monthly_donation_amount: 1)

    rack_login_as(buyer)
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

    rack_login_as(buyer)
    post_purchase(@event, buyer)
    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'purchase is allowed when the activity is closed and the buyer is a signed-in member' do
    create_full_event_hierarchy(event_options: { prices: [0] })
    @activity.set(privacy: 'closed')
    buyer = FactoryBot.create(:account)
    @activity.activityships.create!(account: buyer)

    rack_login_as(buyer)
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

  test 'ticket_form_only does not render the purchase form when the buyer cannot purchase' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })

    get "/e/#{@event.slug}", ticket_form_only: 1

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'id="select-tickets"'
    assert_includes last_response.body, 'monthly donor'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Event manager permissions
  # ═══════════════════════════════════════════════════════════════════════════

  test 'organisations_for_creating_events includes org when account has event_manager on organisationship' do
    org = FactoryBot.create(:organisation)
    other = add_event_manager(org)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events includes org when account is org admin on organisationship' do
    org = FactoryBot.create(:organisation)
    other = add_member(org, admin: true)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events does not include org for plain follower only' do
    org = FactoryBot.create(:organisation)
    follower = add_member(org)
    refute_includes follower.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events includes org from activity admin' do
    org = FactoryBot.create(:organisation)
    activity = FactoryBot.create(:activity, organisation: org)
    other = FactoryBot.create(:account)
    activity.activityships.create!(account: other, admin: true, unsubscribed: false)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events includes org from local group admin' do
    org = FactoryBot.create(:organisation)
    local_group = FactoryBot.create(:local_group, organisation: org)
    other = FactoryBot.create(:account)
    local_group.local_groupships.create!(account: other, admin: true, unsubscribed: false)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'can_create_events_for_organisation? is false for unrelated activity admin' do
    org = FactoryBot.create(:organisation)
    other_org = FactoryBot.create(:organisation, account: org.account)
    activity = FactoryBot.create(:activity, organisation: other_org)
    other = FactoryBot.create(:account)
    activity.activityships.create!(account: other, admin: true, unsubscribed: false)
    refute Organisation.can_create_events_for_organisation?(org, other)
  end

  test 'event is valid for org-wide create when account has event_manager' do
    org = FactoryBot.create(:organisation, allow_event_submissions: false)
    manager = add_event_manager(org)
    event = FactoryBot.build(:event, organisation: org, account: manager, last_saved_by: manager, duplicate: false)
    assert event.valid?, event.errors.full_messages.join(', ')
  end

  test 'event_manager is event admin for organisation event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org)
    assert Event.admin?(event, manager)
  end

  test 'event_manager is event admin for cohosted event' do
    org = FactoryBot.create(:organisation)
    cohost = FactoryBot.create(:organisation)
    manager = add_event_manager(cohost)
    event = FactoryBot.create(:event, organisation: org)
    event.cohostships.create!(organisation: cohost)
    assert Event.admin?(event, manager)
  end

  test 'event_manager is email viewer when show_emails is false' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, show_emails: false)
    assert Event.email_viewer?(event, manager)
  end

  test 'cohost event_manager is email viewer when show_emails is false' do
    org = FactoryBot.create(:organisation)
    cohost = FactoryBot.create(:organisation)
    manager = add_event_manager(cohost)
    event = FactoryBot.create(:event, organisation: org, show_emails: false)
    event.cohostships.create!(organisation: cohost)
    assert Event.email_viewer?(event, manager)
  end

  test 'event is invalid for org-wide create when account is only a follower' do
    org = FactoryBot.create(:organisation, allow_event_submissions: false)
    follower = add_member(org)
    event = FactoryBot.build(:event, organisation: org, account: follower, last_saved_by: follower, duplicate: false)
    refute event.valid?
    assert_includes event.errors[:organisation], "- you don't have permission to create events for this organisation"
  end

  test 'GET /events/new with organisation_id allows event_manager' do
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    manager = add_event_manager(org)
    login_as(manager)
    visit "/events/new?organisation_id=#{org.id}"
    assert page.has_content?('Event title*')
  end

  test 'GET /events/new with organisation_id redirects for plain follower' do
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    follower = add_member(org)
    login_as(follower)
    visit "/events/new?organisation_id=#{org.id}"
    assert_equal '/events', current_path
    assert page.has_content? "don't have permission to create events for this organisation"
  end

  test 'org event manager can delete their own event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, account: manager, last_saved_by: manager)
    login_as(manager)
    visit "/events/#{event.id}/delete"
    accept_confirm do
      click_link 'Delete event and attempt to refund all orders'
    end
    assert_equal "/o/#{org.slug}/events", current_path
    assert page.has_content?('The event was deleted')
    assert event.reload.deleted?
  end

  test 'org event manager cannot delete another account event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org)
    login_as(manager)
    visit "/events/#{event.id}/delete"
    assert page.has_content?("Please ask an admin of #{org.name} to delete the event")
    refute page.has_link?('Delete event and attempt to refund all orders')
    refute event.reload.deleted?
  end

  test 'org admin can delete any organisation event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, account: manager, last_saved_by: manager)
    login_as(org.account)
    visit "/events/#{event.id}/delete"
    accept_confirm do
      click_link 'Delete event and attempt to refund all orders'
    end
    assert_equal "/o/#{org.slug}/events", current_path
    assert event.reload.deleted?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Evergreen events
  # ═══════════════════════════════════════════════════════════════════════════

  test 'creating an evergreen event without dates' do
    create_organisation
    ticket_type = FactoryBot.build_stubbed(:ticket_type)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_in 'Event title*', with: 'On-demand Ruby Course'
    click_link 'Mark as evergreen/on-demand, with no dates or location'
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    refute page.has_content? 'Add to calendar'
  end

  test 'evergreen event appears in future scope' do
    create_evergreen_event
    assert_includes Event.future_current_evergreen.pluck(:id), @event.id
    refute_includes Event.past.pluck(:id), @event.id
    refute_includes Event.finished.pluck(:id), @event.id
  end

  test 'evergreen event instance methods return correct values' do
    event = Event.new(evergreen: true, name: 'Test', currency: 'GBP')
    assert event.future?
    refute event.past?
    refute event.started?
    refute event.finished?
    assert_nil event.when_details('UTC')
    assert_nil event.concise_when_details('UTC')
    assert_nil event.ical
  end

  test 'non-evergreen event still requires start_time end_time location' do
    event = Event.new(name: 'Missing Dates', currency: 'GBP')
    refute event.valid?
    assert event.errors[:start_time].any?
    assert event.errors[:end_time].any?
    assert event.errors[:location].any?
  end

  test 'evergreen event prevents duplicate names within same organisation' do
    create_evergreen_event(name: 'My Course')
    duplicate = Event.new(
      name: 'My Course',
      currency: 'GBP',
      organisation: @organisation,
      account: @account,
      last_saved_by: @account,
      evergreen: true
    )
    refute duplicate.valid?
    assert duplicate.errors[:name].any?
  end

  test 'duplicating an evergreen event preserves the flag' do
    create_evergreen_event
    duplicate = @event.duplicate!(@account)
    assert duplicate.evergreen?
    assert_nil duplicate.start_time
    assert_nil duplicate.end_time
  end

  test 'booking onto a free evergreen event' do
    create_evergreen_event
    login_as(@account)
    visit "/e/#{@event.slug}"
    assert page.has_content? 'Online'
    assert page.has_content? 'Register for free'
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
  end

  test 'evergreen event reminder_due_within returns false' do
    event = Event.new(evergreen: true, name: 'Test', currency: 'GBP', reminder_hours_before: 24)
    refute event.reminder_due_within?(1.hour)
  end

  test 'evergreen event feedback_due_within returns false' do
    event = Event.new(
      evergreen: true,
      name: 'Test',
      currency: 'GBP',
      feedback_questions: 'Q?',
      end_time: 1.day.ago,
      feedback_hours_after: 1
    )
    refute event.feedback_due_within?(1.hour)
  end

  test 'evergreen event json endpoint returns nil dates' do
    create_evergreen_event

    get "/e/#{@event.slug}.json"

    assert_equal 200, last_response.status
    json = JSON.parse(last_response.body)
    assert_equal @event.name, json['name']
    assert_nil json['start_time']
    assert_nil json['end_time']
  end

  test 'organisation orders page renders evergreen orders' do
    create_evergreen_order

    login_as(@account)
    visit "/o/#{@organisation.slug}/orders"

    assert page.has_content? @event.name
    assert page.has_content? @attendee.name
  end

  test 'evergreen event calendar endpoints return not found' do
    create_evergreen_order

    get "/e/#{@event.slug}.ics"
    assert_equal 404, last_response.status
    get "/orders/#{@order.id}.ics"
    assert_equal 404, last_response.status
  end

  test 'converting a scheduled event to evergreen wipes start time, end time, and location' do
    create_event(location: 'London', prices: [0])
    assert @event.start_time
    assert @event.end_time
    @event.update!(evergreen: true)
    @event.reload
    assert_nil @event.start_time
    assert_nil @event.end_time
    assert_equal 'Online', @event.location
  end
end
