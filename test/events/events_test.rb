require_relative '../test_config'

# Creating, editing, locking and duplicating events, reminders, feedback requests and recordings
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

  test 'creating an event' do
    create_organisation
    event = FactoryBot.build_stubbed(:event)
    ticket_type = FactoryBot.build_stubbed(:ticket_type)
    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_event_create_form(event, ticket_type)
    click_button 'Create event'
    assert page.has_content? 'Add to calendar'
  end

  test 'adding a facilitator updates the facilitators box in place, without reloading the page' do
    covers_route 'GET /e/:slug/event_facilitations'
    covers_route 'POST /e/:slug/event_facilitations/new'
    create_event
    facilitator = FactoryBot.create(:account, name: 'Maya Okoro', has_signed_in: true)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    page.execute_script('window.notReloaded = true')

    box = "[data-pagelet-url='/e/#{@event.slug}/event_facilitations']"
    within(box) do
      find('.add-role-toggle').click
      find('.select2-selection').click
    end
    # select2 puts its search and results at the end of the page, outside the box
    find('.select2-search__field').send_keys('Maya')
    find('.select2-results__option', text: facilitator.name).click
    within(box) { click_button 'Add event facilitator' }

    assert page.has_css? "#{box} img[alt='#{facilitator.name}']"
    assert @event.event_facilitations.find_by(account: facilitator)
    assert page.evaluate_script('window.notReloaded')
  end

  test 'creating an event with a range' do
    covers 'events/price-range-slider@693b77'
    create_organisation
    event = FactoryBot.build_stubbed(:event)
    ticket_type = FactoryBot.build_stubbed(:ticket_type, price_or_range: '10-100')
    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_event_create_form(event, ticket_type)
    click_button 'Create event'
    assert page.has_content? 'Drag the slider'
  end

  test 'editing an event' do
    create_event(prices: [0])
    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    fill_in 'Event title*', with: (name = FactoryBot.build_stubbed(:event).name)
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert page.has_content? name
  end

  test 'ticket type slots are chosen from standard, add-on and couple' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    click_link 'Tickets'
    assert page.has_css? 'select.slots-choice option[selected]', text: 'Standard: 1 place'
    assert page.has_no_field? 'event_ticket_types_attributes_0_slots'
    find('select.slots-choice').select 'Add-on: no places (not counted towards capacity)'
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert_equal 0, ticket_type.reload.slots
  end

  test 'other ticket type slots are typed in' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    click_link 'Tickets'
    find('select.slots-choice').select 'Other…'
    fill_in 'event_ticket_types_attributes_0_slots', with: 4
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert_equal 4, ticket_type.reload.slots

    visit "/e/#{@event.slug}/edit"
    click_link 'Tickets'
    assert page.has_css? 'select.slots-choice option[selected]', text: 'Other…'
    assert page.has_field? 'event_ticket_types_attributes_0_slots', with: '4'
  end

  test 'public event submission creates draft and notifies admins' do
    covers 'organisations/who-becomes-event-admin@459b2f', 'organisations/community-event-submissions@e06059'
    Delayed::Job.delete_all if defined?(Delayed::Job)
    create_organisation(allow_event_submissions: true)
    submitter = FactoryBot.create(:account)
    event = FactoryBot.build_stubbed(:event)

    sign_in(submitter)
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
    assert page.has_no_css?('label[for="event_locked"]'), 'Submitter should not see locked checkbox'
    assert page.has_content?('submitted for review'), 'Submitter should see unlock message'
  end

  test 'event admin can lock but only lock admin can unlock' do
    covers 'organisations/who-becomes-event-admin@459b2f', 'organisations/community-event-submissions@e06059', 'organisations/table-unlock-locked@ec36f3'
    create_organisation(allow_event_submissions: true)
    org_admin = @account
    coordinator = FactoryBot.create(:account)
    create_event(coordinator: coordinator, locked: false, prices: [0])

    assert Event.admin?(@event, coordinator), 'Coordinator should be event admin'
    refute Event.lock_admin?(@event, coordinator), 'Coordinator should not be lock admin'

    # Event admin (coordinator) can lock an unlocked event
    sign_in(coordinator)
    visit "/e/#{@event.slug}/edit"
    assert page.has_css?('label[for="event_locked"]'), 'Event admin should see locked checkbox when event is unlocked'
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    assert @event.reload.locked?, 'Event should be locked after event admin checks the box'

    # Event admin (coordinator) cannot unlock - checkbox should be hidden
    visit "/e/#{@event.slug}/edit"
    assert page.has_no_css?('label[for="event_locked"]'), 'Event admin should not see locked checkbox when event is locked (cannot unlock)'
    assert page.has_content?('submitted for review'), 'Non-lock-admin should see unlock message'

    # Lock admin (org admin) can unlock
    sign_in(org_admin)
    visit "/e/#{@event.slug}/edit"
    assert page.has_css?('label[for="event_locked"]'), 'Lock admin should see locked checkbox'
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    refute @event.reload.locked?, 'Event should be unlocked after lock admin unchecks the box'
  end

  test 'event locked after a purchase error shows the error until unlocked' do
    create_event(prices: [0])
    @event.set(locked: true, locked_error: 'Creditor account not fully verified', locked_error_provider: 'GoCardless')

    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    assert page.has_content?('We received an error from GoCardless when someone tried to buy tickets')
    assert page.has_content?('Creditor account not fully verified')
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    @event.reload
    refute @event.locked?
    assert_nil @event.locked_error
    assert_nil @event.locked_error_provider
  end

  test 'a duplicated event says it is a copy until it is first saved' do
    covers 'events/duplicate-starts-locked@9b7b43'
    covers_route 'GET /e/:slug/feedback_questions'
    covers_route 'GET /e/:slug/questions'
    create_event(prices: [0])
    sign_in(@account)
    duplicate = @event.duplicate!(@account)
    assert_equal @event, duplicate.duplicated_from

    visit "/e/#{duplicate.slug}/edit"
    assert page.has_content?("This is a duplicate of #{@event.name}")
    assert page.has_link?(@event.name, href: "/e/#{@event.slug}/edit")
    visit "/e/#{@event.slug}/edit"
    assert page.has_content?('Event title')
    assert page.has_no_content?('duplicate of')

    duplicate.name = nil
    refute duplicate.save
    assert_equal @event, duplicate.duplicated_from, 'A save that fails validation keeps the banner'
    duplicate.reload.save!
    assert_nil duplicate.reload.duplicated_from_id
    visit "/e/#{duplicate.slug}/edit"
    assert page.has_content?('Event title')
    assert page.has_no_content?('duplicate of')
  end

  test 'new events, duplicates included, give nothing to category stewards or social media' do
    create_event(prices: [0])
    @event.set(profit_share_to_category_steward: 10, profit_share_to_social_media: 5)
    @event.reload
    @event.save!
    assert_equal [10, 5], [@event.reload.profit_share_to_category_steward, @event.profit_share_to_social_media], 'Events from before keep their shares'

    duplicate = @event.duplicate!(@account)
    assert_equal 0, duplicate.profit_share_to_category_steward
    assert_equal 0, duplicate.profit_share_to_social_media

    event = Event.create!(@event.attributes.slice('name', 'location', 'currency').merge(start_time: 1.week.from_now, end_time: 1.week.from_now + 1.hour, account: @account, organisation: @organisation, profit_share_to_category_steward: 10, profit_share_to_social_media: 5))
    assert_equal [0, 0], [event.reload.profit_share_to_category_steward, event.profit_share_to_social_media]
  end

  test 'event page views are counted until the event starts' do
    create_event(prices: [0])

    2.times { get "/e/#{@event.slug}" }
    get "/e/#{@event.slug}.json"
    assert_equal 2, @event.reload.page_views_count

    @event.set(start_time: 1.hour.ago)
    get "/e/#{@event.slug}"
    assert last_response.ok?
    assert_equal 2, @event.reload.page_views_count
  end

  test 'nested ticket type cannot reference another event ticket group' do
    create_event(prices: [0])
    own_group = @event.ticket_groups.create!(name: 'Own', capacity: 10)
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    other_event = FactoryBot.create(:event, organisation: other_organisation, prices: [0])
    other_group = other_event.ticket_groups.create!(name: 'Backstage', capacity: 10)
    ticket_type = @event.ticket_types.first

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/edit", event: {
      ticket_types_attributes: { '0' => { id: ticket_type.id.to_s, name: ticket_type.name, quantity: ticket_type.quantity.to_s, ticket_group_id: other_group.id.to_s } }
    }

    refute last_response.redirect?
    assert_nil ticket_type.reload.ticket_group_id
    assert_empty other_group.tickets

    post "/e/#{@event.slug}/edit", event: {
      ticket_types_attributes: { '0' => { id: ticket_type.id.to_s, name: ticket_type.name, quantity: ticket_type.quantity.to_s, ticket_group_id: own_group.id.to_s } }
    }

    assert last_response.redirect?, last_response.body
    assert_equal own_group.id, ticket_type.reload.ticket_group_id
  end

  test 'nested ticket types and groups cannot be moved to another event' do
    create_event(prices: [0])
    own_group = @event.ticket_groups.create!(name: 'Own', capacity: 10)
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    other_event = FactoryBot.create(:event, organisation: other_organisation, prices: [0])
    ticket_type = @event.ticket_types.first

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/edit", event: {
      ticket_types_attributes: { '0' => { id: ticket_type.id.to_s, name: ticket_type.name, quantity: ticket_type.quantity.to_s, event_id: other_event.id.to_s } },
      ticket_groups_attributes: { '0' => { id: own_group.id.to_s, name: own_group.name, capacity: own_group.capacity.to_s, event_id: other_event.id.to_s } }
    }

    # mass_assigning drops event_id, so the event saves with both left where they were
    assert last_response.redirect?
    assert_equal @event.id, ticket_type.reload.event_id
    assert_equal @event.id, own_group.reload.event_id
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

  test 'reminder is due when its send time falls within the next hour' do
    covers 'events/reminder-before-event@004602'
    now = Time.utc(2026, 3, 13, 8, 55, 0)
    event = Event.new(start_time: Time.utc(2026, 3, 13, 10, 0, 0), reminder_hours_before: 1)

    assert event.reminder_due_within?(1.hour, now)
  end

  test 'reminder is not due once the event has started' do
    covers 'events/reminder-before-event@004602'
    now = Time.utc(2026, 3, 13, 10, 0, 0)
    event = Event.new(start_time: now - 5.minutes, reminder_hours_before: 1)

    refute event.reminder_due_within?(1.hour, now)
  end

  test 'feedback request is due when its send time falls within the next hour' do
    covers 'events/feedback-request-after-event@2bacdf'
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
    covers 'events/feedback-request-blank-at-end@f0b3f9'
    now = Time.utc(2026, 3, 13, 9, 55, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0)
    )

    assert event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request is not sent once it has already been sent' do
    covers 'events/feedback-request-after-event@2bacdf'
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
    covers 'events/feedback-request-max-30-days@52678f'
    event = Event.new(feedback_hours_after: Event::MAX_FEEDBACK_HOURS_AFTER + 1)
    event.valid?

    assert_includes event.errors[:feedback_hours_after], "cannot be more than #{Event::MAX_FEEDBACK_HOURS_AFTER}"
  end

  test 'event gathering must be administered by the last saver' do
    create_event
    other_account = FactoryBot.create(:account)
    other_gathering = FactoryBot.create(:gathering, account: other_account)
    @event.gathering = other_gathering
    @event.last_saved_by = @account

    refute @event.valid?
    assert_includes @event.errors[:gathering], "- you don't have permission to add attendees to this gathering"
  end

  test 'event session create rejects event_id from params' do
    covers_route 'POST /e/:slug/event_sessions/new'
    create_event(prices: [0])
    other_event = FactoryBot.create(:event)

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/event_sessions/new", event_session: {
      start_time: (@event.start_time + 1.hour).iso8601,
      end_time: (@event.end_time - 1.hour).iso8601,
      event_id: other_event.id
    }

    assert_equal 1, @event.event_sessions.count
    assert_equal 0, other_event.event_sessions.count
  end

  test 'event edit ignores deleted_at and timestamps from params' do
    create_event(prices: [0])
    created_at = @event.created_at

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/edit", event: { name: 'Renamed', deleted_at: '2020-01-01', created_at: '2020-01-01' }

    event = Event.unscoped.find(@event.id)
    assert_equal 'Renamed', event.name
    assert_nil event.deleted_at
    assert_equal created_at.to_i, event.created_at.to_i
  end

  test 'rpayment edit rejects event_id from params' do
    covers_route 'POST /e/:event_slug/rpayments/:id/edit'
    create_event(prices: [0])
    other_event = FactoryBot.create(:event)
    rpayment = @event.rpayments.create!(account: @account, amount: 10, currency: @event.currency, role: Rpayment.roles.first)

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/rpayments/#{rpayment.id}/edit", rpayment: {
      amount: 10,
      currency: @event.currency,
      role: rpayment.role,
      event_id: other_event.id
    }

    assert_equal @event.id, rpayment.reload.event_id
  end

  test 'saving an event does not read an image that is not new' do
    create_event
    # Stored and measured directly, as an earlier upload would have left it, so the test doesn't need ImageMagick
    uid = Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg'))
    @event.set(image_uid: uid, image_width_unmagic: 1920, image_height_unmagic: 1080)

    event = Event.find(@event.id)
    Dragonfly.app.datastore.stub(:read, ->(*) { raise 'read an unchanged image' }) do
      event.update_attributes!(name: 'Renamed')
    end
    assert_equal 1920, event.reload.image_width_unmagic
  end

  test 'a duplicated event starts locked' do
    covers 'events/duplicate-starts-locked@9b7b43'
    covers_route 'POST /e/:slug/duplicate'
    create_event(prices: [0], locked: false)
    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    click_button @event.name
    click_link_and_confirm 'Duplicate event'
    assert page.has_content?("This is a duplicate of #{@event.name}")
    duplicate = Event.find_by(duplicated_from_id: @event.id)
    assert page.has_current_path?("/e/#{duplicate.slug}/edit")
    assert duplicate.locked?
    refute @event.reload.locked?
  end

  test 'a new event defaults to a reminder 24 hours before it' do
    covers 'events/reminder-default-and-blank@b3faac'
    covers_route 'GET /events/new'
    create_organisation
    sign_in_with_rack(@account)
    get '/events/new', organisation_id: @organisation.id
    assert_equal 200, last_response.status
    assert_match(/<input[^>]*name="event\[reminder_hours_before\]"[^>]*value="24"|<input[^>]*value="24"[^>]*name="event\[reminder_hours_before\]"/, last_response.body)
  end

  test 'leaving the reminder hours blank skips the reminder' do
    covers 'events/reminder-default-and-blank@b3faac'
    create_event(prices: [0], start_time: 2.hours.from_now, end_time: 3.hours.from_now, reminder_hours_before: nil)
    order = @event.orders.create!(account: @account, currency: 'GBP', value: 0, payment_completed: true)
    @event.tickets.create!(account: @account, order: order, ticket_type: @event.ticket_types.first, payment_completed: true)

    refute @event.reminder_due_within?(1.hour)
    assert_empty(recorded_emails { @event.send_reminders_without_delay(:all) })
    assert_nil @event.reload.sent_reminders_at
  end

  test 'the reminder email subject and body can be customised by the organisation and the event' do
    covers 'events/reminder-custom-subject-body@179fcd'
    create_organisation(reminder_email_title: 'Organisation reminder for [event_name]', reminder_email_body: '<p>Organisation reminder body</p>')
    create_event(name: 'Reminded event', prices: [0], start_time: 2.hours.from_now, end_time: 3.hours.from_now, reminder_hours_before: 24)
    order = @event.orders.create!(account: @account, currency: 'GBP', value: 0, payment_completed: true)
    @event.tickets.create!(account: @account, order: order, ticket_type: @event.ticket_types.first, payment_completed: true)

    emails = recorded_emails { @event.send_reminders_without_delay(@account.id) }
    assert_equal ['Organisation reminder for Reminded event'], emails.map(&:subject_line).uniq
    emails.each { |email| assert_includes email.html, 'Organisation reminder body' }
    assert_equal [@account.email], emails.flat_map(&:recipients)

    @event.update!(reminder_email_title: 'Event reminder for [event_name]', reminder_email_body: '<p>Event reminder body</p>')
    emails = recorded_emails { @event.send_reminders_without_delay(@account.id) }
    assert_equal ['Event reminder for Reminded event'], emails.map(&:subject_line).uniq
    emails.each do |email|
      assert_includes email.html, 'Event reminder body'
      refute_includes email.html, 'Organisation reminder body'
    end
  end

  test 'a past event with a recording keeps its date and tells buyers they are getting a recording' do
    covers 'events/recording-keeps-date@836029'
    start_time = 3.days.ago.change(hour: 10)
    create_event(prices: [0], start_time: start_time, end_time: start_time + 2.hours, extra_info_for_recording_email: '<p>Watch it here</p>')
    @event.reload
    assert @event.recording?
    assert_equal start_time.to_i, @event.start_time.to_i

    get "/e/#{@event.slug}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Access a recording of this event that started on #{start_time.to_date}"
  end

  test 'the recording tab appears once the event is past' do
    covers 'events/recording-tab-once-past@64905b'
    create_event(prices: [0])
    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/edit"
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'href="#tab-recording"'

    @event.update!(start_time: 2.days.ago, end_time: 2.days.ago + 2.hours)
    get "/e/#{@event.slug}/edit"
    assert_includes last_response.body, 'href="#tab-recording"'
    assert_includes last_response.body, 'event[extra_info_for_recording_email]'
  end

  test 'extra info for a recording is in the confirmation emails of bookings made once the event is past' do
    covers 'events/recording-extra-info-in-confirmation@b014b8'
    create_event(prices: [0], extra_info_for_recording_email: '<p>Recording link: https://vimeo.com/1</p>', extra_info_for_ticket_email: '<p>Zoom link</p>')
    order = @event.orders.new(account: @account)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: '', header_image_url: nil)
    assert_includes html, 'Zoom link'
    refute_includes html, 'Recording link'

    @event.update!(start_time: 2.days.ago, end_time: 2.days.ago + 2.hours)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: '', header_image_url: nil)
    assert_includes html, 'Recording link: https://vimeo.com/1'
    refute_includes html, 'Zoom link'
  end

  test 'URLs that name an event, organisation, activity, local group or account by id redirect to its slug URL' do
    covers_route 'GET /accounts/:id'
    covers_route 'GET /activities/:id'
    covers_route 'GET /events/:id'
    covers_route 'GET /events/:id/*'
    covers_route 'GET /local_groups/:id/*'
    covers_route 'GET /organisations/:id/*'
    covers_route 'POST /events/:id/*'
    create_full_event_hierarchy
    {
      "/events/#{@event.id}" => "/e/#{@event.slug}",
      "/events/#{@event.id}/edit?tab=tickets" => "/e/#{@event.slug}/edit?tab=tickets",
      "/organisations/#{@organisation.id}/events" => "/o/#{@organisation.slug}/events",
      "/activities/#{@activity.id}" => @activity.path,
      "/local_groups/#{@local_group.id}/edit" => "#{@local_group.path}/edit",
      "/accounts/#{@account.id}" => "/u/#{@account.username}"
    }.each do |id_url, slug_url|
      get id_url
      assert_equal 307, last_response.status, id_url
      assert_equal "http://example.org#{slug_url}", last_response.location
    end

    # A 307 keeps the method and body, so a form still posting to the old URL reaches the new one
    post "/events/#{@event.id}/edit", event: { name: 'Renamed' }
    assert_equal 307, last_response.status
    assert_equal "http://example.org/e/#{@event.slug}/edit", last_response.location

    get "/events/#{BSON::ObjectId.new}"
    assert_equal 404, last_response.status
  end

  test 'ticket_form_only limits the event page to the ticket form' do
    covers 'events/embed-ticket-form-only@7366b1'
    create_event(prices: [0], description: '<p>A description only the full event page shows</p>')

    # The page body, after the head's meta description
    page_body = -> { last_response.body.split('</head>', 2).last }

    get "/e/#{@event.slug}"
    assert_includes page_body.call, 'A description only the full event page shows'
    assert_includes page_body.call, 'id="select-tickets"'
    assert_includes page_body.call, 'id="header"'

    get "/e/#{@event.slug}", ticket_form_only: 1
    assert_equal 200, last_response.status
    assert_includes page_body.call, 'id="select-tickets"'
    refute_includes page_body.call, 'A description only the full event page shows'
    refute_includes page_body.call, 'id="header"'
  end
end
