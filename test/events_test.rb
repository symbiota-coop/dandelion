require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventsTest < ActiveSupport::TestCase
  include Capybara::DSL

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

  def add_member(org, **attrs)
    account = FactoryBot.create(:account)
    account.organisationships.create!(organisation: org, unsubscribed: false, **attrs)
    account
  end

  def add_event_manager(org)
    add_member(org, event_manager: true)
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

  test 'organisation_id and account_id cannot be reassigned on update' do
    create_event(prices: [0])
    assert_cannot_reassign_organisation_or_account(@event)
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
  # Reminders and feedback
  # ═══════════════════════════════════════════════════════════════════════════

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
end
