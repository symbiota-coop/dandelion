require_relative '../test_config'

# An event's admin pages and pagelets (app/controllers/events_admin.rb, rpayments.rb, check_in.rb): duplicating, sessions,
# waitlists, stats, revenue payments and check-in, and that nobody else can reach them. Also starring an event, its
# sessions' calendar files, deleting a draft and the event boosts Stripe webhook
class EventAdminRoutesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  BOOSTS_SECRET = 'whsec_event_boosts_test'.freeze
  ADMIN_NOTIFICATION_JOB = /method_name: :send_admin_notification_without_delay/

  # Someone who admins only this event, as its facilitator
  def create_facilitator(event)
    FactoryBot.create(:account).tap { |account| event.event_facilitations.create!(account: account) }
  end

  def create_waiter(name)
    FactoryBot.create(:account, name: name, email: "#{name.parameterize}@example.com")
  end

  def create_event_session(event, start_offset: 1.hour, length: 1.hour)
    event.event_sessions.create!(start_time: event.start_time + start_offset, end_time: event.start_time + start_offset + length)
  end

  # Duplicating

  test 'an event admin duplicates an event from its duplicate page, with its ticket types but none of its bookings' do
    covers_route 'GET /e/:slug/duplicate'
    create_event(prices: [10], secret: true, capacity: 20)
    attendee = FactoryBot.create(:account)
    order = @event.orders.create!(account: attendee, currency: @event.currency, value: 10, payment_completed: true)
    order.tickets.create!(event: @event, account: attendee, ticket_type: @event.ticket_types.first, price: 10)
    @event.waitships.create!(account: FactoryBot.create(:account))
    @event.event_stars.create!(account: attendee)
    facilitator = create_facilitator(@event)
    sign_in(facilitator)

    visit "/e/#{@event.slug}/duplicate"
    click_link 'Duplicate event'
    assert page.has_content?("This is a duplicate of #{@event.name}")
    duplicate = Event.find_by(duplicated_from_id: @event.id)
    assert page.has_current_path?("/e/#{duplicate.slug}/edit")

    assert_equal @event.ticket_types.pluck(:name, :price), duplicate.ticket_types.pluck(:name, :price)
    assert duplicate.secret?
    assert_equal 20, duplicate.capacity
    assert duplicate.event_facilitations.find_by(account: facilitator)
    assert_equal facilitator, duplicate.account
    assert_equal 0, duplicate.orders.count
    assert_equal 0, duplicate.tickets.count
    assert_equal 0, duplicate.waitships.count
    assert_equal 0, duplicate.event_stars.count
  end

  test "someone who isn't an admin of the event can't duplicate it" do
    create_event(prices: [10])
    other_event = FactoryBot.create(:event)
    outsider = create_facilitator(other_event)
    sign_in_with_rack(outsider)

    get "/e/#{@event.slug}/duplicate"
    assert last_response.redirect?
    post "/e/#{@event.slug}/duplicate"
    assert last_response.redirect?
    assert_nil Event.find_by(duplicated_from_id: @event.id)
  end

  # Sessions

  test 'an event admin adds and removes a session in the sessions box' do
    covers_route 'GET /e/:slug/event_sessions'
    covers_route 'POST /e/:slug/event_sessions/destroy'
    create_event(prices: [0])
    create_event_session(@event)
    sign_in(@account)

    visit "/e/#{@event.slug}"
    assert page.has_content?('1 session')
    find('#remove-event-session').click
    click_button 'Remove session'
    # The box reloads from /e/:slug/event_sessions once the session is removed
    assert page.has_css?('#add-event-session')
    assert page.has_no_content?('1 session')
    assert_equal 0, @event.event_sessions.count
  end

  test "an event's sessions box and removing its sessions are refused to others, and another event's session can't be removed" do
    create_event(prices: [0])
    event_session = create_event_session(@event)
    other_event = FactoryBot.create(:event)
    other_session = create_event_session(other_event)
    sign_in_with_rack(create_facilitator(other_event))

    get "/e/#{@event.slug}/event_sessions", {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert_equal 403, last_response.status
    post "/e/#{@event.slug}/event_sessions/destroy", event_session_id: event_session.id
    assert last_response.redirect?
    assert EventSession.find(event_session.id)

    # As an admin of other_event, naming this event's session
    post "/e/#{other_event.slug}/event_sessions/destroy", event_session_id: event_session.id
    assert EventSession.find(event_session.id)
    assert EventSession.find(other_session.id)
  end

  test "a session's calendar file has its times and the event's name" do
    covers_route 'GET /event_sessions/:id'
    create_event(prices: [0], name: 'Weekly sitting')
    event_session = create_event_session(@event)

    get "/event_sessions/#{event_session.id}.ics"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "DTSTART:#{event_session.start_time.utc.strftime('%Y%m%dT%H%M%SZ')}"
    assert_includes last_response.body, 'SUMMARY:Weekly sitting\, session 1/1'

    get "/event_sessions/#{BSON::ObjectId.new}.ics"
    assert_equal 404, last_response.status

    @event.destroy
    get "/event_sessions/#{event_session.id}.ics"
    assert_equal 404, last_response.status
  end

  # Pagelets and pages only event admins see

  test 'only event admins get the progress pagelet' do
    covers_route 'GET /e/:slug/progress'
    create_event(prices: [0])
    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/progress", full_width: true
    assert_equal 200, last_response.status
    assert_includes last_response.body, '0 tickets'

    sign_in_with_rack(FactoryBot.create(:account))
    get "/e/#{@event.slug}/progress", {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert_equal 403, last_response.status
  end

  test "the linked image is the event's image, for its admins only" do
    covers_route 'GET /e/:slug/linked_image'
    create_event(prices: [0])
    sign_in_with_rack(@account)

    get "/e/#{@event.slug}/linked_image", organisation_id: @organisation.id
    assert_equal 404, last_response.status # no image yet

    # Stored directly, as an upload would have left it, so the test doesn't need ImageMagick
    @event.set(image_uid: Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg')))
    get "/e/#{@event.slug}/linked_image", organisation_id: @organisation.id
    assert_equal 200, last_response.status
    assert_includes last_response.body, %(href="#{ENV['BASE_URI']}/e/#{@event.slug}")
    assert_includes last_response.body, '<img'

    get "/e/#{@event.slug}/linked_image", organisation_id: BSON::ObjectId.new
    assert_equal 404, last_response.status

    sign_in_with_rack(FactoryBot.create(:account))
    get "/e/#{@event.slug}/linked_image", organisation_id: @organisation.id
    assert last_response.redirect?
  end

  test "an event admin sees the event's audience stats, and others are turned away without them" do
    covers_route 'GET /e/:slug/stats'
    create_event(prices: [0])
    attendee = FactoryBot.create(:account, name: 'Audience Member')
    order = @event.orders.create!(account: attendee, currency: @event.currency, value: 0, payment_completed: true)
    order.tickets.create!(event: @event, account: attendee, ticket_type: @event.ticket_types.first, price: 0, payment_completed: true)

    sign_in_with_rack(create_facilitator(@event))
    get "/e/#{@event.slug}/stats"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Attendees'
    assert_includes last_response.body, 'Audience Member'

    sign_in_with_rack(FactoryBot.create(:account))
    get "/e/#{@event.slug}/stats"
    assert last_response.redirect?
    follow_redirect!
    refute_includes last_response.body, 'Audience Member'
  end

  test "an event admin sees the event's waitlist, and others are turned away without it" do
    covers_route 'GET /e/:slug/waitlist'
    create_event(prices: [0])
    waiter = create_waiter('Waiting Person')
    @event.waitships.create!(account: waiter)

    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/waitlist"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Waiting Person'
    assert_includes last_response.body, waiter.email

    sign_in_with_rack(create_facilitator(FactoryBot.create(:event)))
    get "/e/#{@event.slug}/waitlist"
    assert last_response.redirect?
    follow_redirect!
    refute_includes last_response.body, 'Waiting Person'
    refute_includes last_response.body, waiter.email
  end

  test "an event admin sees the ticket type waitlists, filtered by ticket type, and others are turned away without them" do
    covers_route 'GET /e/:slug/ticket_type_waitlists'
    create_event(allow_ticket_type_waitlists: true)
    # Waitlists are for sold-out ticket types
    first_type = FactoryBot.create(:ticket_type, event: @event, quantity: 0, name: 'Weekend pass')
    second_type = FactoryBot.create(:ticket_type, event: @event, quantity: 0, name: 'Day pass')
    weekend_waiter = create_waiter('Weekend Waiter')
    TicketTypeWaitship.create!(ticket_type: first_type, account: weekend_waiter)
    TicketTypeWaitship.create!(ticket_type: second_type, account: create_waiter('Day Waiter'))
    other_event = FactoryBot.create(:event, allow_ticket_type_waitlists: true)
    other_type = FactoryBot.create(:ticket_type, event: other_event, quantity: 0)
    TicketTypeWaitship.create!(ticket_type: other_type, account: create_waiter('Elsewhere Waiter'))

    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/ticket_type_waitlists"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Weekend Waiter'
    assert_includes last_response.body, 'Day Waiter'
    refute_includes last_response.body, 'Elsewhere Waiter'

    get "/e/#{@event.slug}/ticket_type_waitlists", ticket_type_id: first_type.id
    assert_includes last_response.body, 'Weekend Waiter'
    refute_includes last_response.body, 'Day Waiter'

    sign_in_with_rack(FactoryBot.create(:account))
    get "/e/#{@event.slug}/ticket_type_waitlists"
    assert last_response.redirect?
    follow_redirect!
    refute_includes last_response.body, 'Weekend Waiter'
    refute_includes last_response.body, weekend_waiter.email
  end

  test "an event admin sees the ticket types' photos page, and others are turned away" do
    covers_route 'GET /e/:slug/ticket_types'
    create_event(prices: [10])
    @event.ticket_types.first.update_attributes!(name: 'Residential place')

    sign_in_with_rack(create_facilitator(@event))
    get "/e/#{@event.slug}/ticket_types"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Residential place'

    sign_in_with_rack(FactoryBot.create(:account))
    get "/e/#{@event.slug}/ticket_types"
    assert last_response.redirect?
  end

  # Starring

  test 'someone stars an event from its page and unstars it again' do
    covers_route 'GET /e/:slug/star'
    covers_route 'POST /e/:slug/do_star'
    covers_route 'POST /e/:slug/unstar'
    create_event(prices: [0])
    starrer = FactoryBot.create(:account)
    sign_in(starrer)

    visit "/e/#{@event.slug}"
    find("a[href='/e/#{@event.slug}/do_star']").click
    # The star reloads from /e/:slug/star, filled in
    assert page.has_css?("a[href='/e/#{@event.slug}/unstar'] .bi-star-fill")
    assert @event.event_stars.find_by(account: starrer)

    find("a[href='/e/#{@event.slug}/unstar']").click
    assert page.has_css?("a[href='/e/#{@event.slug}/do_star'] .bi-star")
    refute @event.event_stars.find_by(account: starrer)
  end

  test 'starring is only ever as yourself, and needs signing in' do
    create_event(prices: [0])
    someone_else = FactoryBot.create(:account)
    @event.event_stars.create!(account: someone_else)

    post "/e/#{@event.slug}/do_star"
    assert last_response.redirect?
    assert_equal 1, @event.event_stars.count

    starrer = FactoryBot.create(:account)
    sign_in_with_rack(starrer)
    post "/e/#{@event.slug}/do_star", account_id: someone_else.id
    assert_equal 200, last_response.status
    assert @event.event_stars.find_by(account: starrer)
    assert_equal 2, @event.event_stars.count

    post "/e/#{@event.slug}/unstar", account_id: someone_else.id
    refute @event.event_stars.find_by(account: starrer)
    assert @event.event_stars.find_by(account: someone_else)
  end

  # Drafts

  test 'someone deletes their own draft from the new event page' do
    covers_route 'POST /drafts/:id/destroy'
    create_organisation
    draft = @account.drafts.create!(model: 'Event', name: 'Half-written retreat', url: "/events/new?organisation_id=#{@organisation.id}", json: { name: 'Half-written retreat' }.to_json)
    sign_in(@account)

    visit "/events/new?organisation_id=#{@organisation.id}"
    within('#drafts') { assert page.has_content?('Half-written retreat') }
    find('#drafts .bi-x-lg').click
    # The draft goes in the background, and then its list from the page
    page.document.synchronize { raise Capybara::ExpectationNotMet, 'draft not deleted yet' if Draft.find(draft.id) }
    assert page.has_no_css?('#drafts')
  end

  test "someone can't delete another account's draft" do
    owner = FactoryBot.create(:account)
    draft = owner.drafts.create!(model: 'Event', name: 'Mine', url: '/events/new', json: '{}')

    post "/drafts/#{draft.id}/destroy"
    assert last_response.redirect?

    sign_in_with_rack(FactoryBot.create(:account))
    post "/drafts/#{draft.id}/destroy"
    assert_equal 404, last_response.status
    assert Draft.find(draft.id)
  end

  # Revenue payments

  test 'an organisation admin records a revenue payment for an event and deletes it' do
    covers_route 'GET /e/:event_slug/rpayments'
    covers_route 'POST /e/:event_slug/rpayments/new'
    covers_route 'POST /e/:event_slug/rpayments/:id/destroy'
    create_event(prices: [10])
    sign_in(@account)

    visit "/e/#{@event.slug}/rpayments"
    click_link 'Add payment'
    select 'coordinator', from: 'rpayment_role'
    fill_in 'rpayment_amount', with: '25'
    select @event.currency, from: 'rpayment_currency'
    fill_in 'rpayment_notes', with: 'Paid by bank transfer'
    click_button 'Create payment'
    assert page.has_content?('Paid by bank transfer')
    rpayment = @event.rpayments.first
    assert_equal ['coordinator', 25.0, @event.currency, @account.id], [rpayment.role, rpayment.amount, rpayment.currency, rpayment.account_id]

    find("a[href='/e/#{@event.slug}/rpayments/#{rpayment.id}/destroy']").click
    page.document.find('.popover').click_button 'Confirm'
    page.document.synchronize { raise Capybara::ExpectationNotMet, 'payment not deleted yet' if @event.rpayments.exists? }
    assert page.has_no_content?('Paid by bank transfer')
  end

  test "only the organisation's admins can see, record, edit or delete an event's revenue payments" do
    covers_route 'GET /e/:event_slug/rpayments/:id/edit'
    create_event(prices: [10])
    rpayment = @event.rpayments.create!(account: @account, amount: 10, currency: @event.currency, role: 'organiser')

    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/rpayments/#{rpayment.id}/edit"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Save payment'

    # An event admin who isn't one of the organisation's admins, and the event's revenue sharer
    revenue_sharer = FactoryBot.create(:account)
    @event.set(revenue_sharer_id: revenue_sharer.id)
    [create_facilitator(@event), revenue_sharer].each do |account|
      sign_in_with_rack(account)
      get "/e/#{@event.slug}/rpayments"
      assert last_response.redirect?
      get "/e/#{@event.slug}/rpayments/#{rpayment.id}/edit"
      assert last_response.redirect?
      post "/e/#{@event.slug}/rpayments/new", rpayment: { role: 'organiser', amount: 99, currency: @event.currency }
      assert last_response.redirect?
      post "/e/#{@event.slug}/rpayments/#{rpayment.id}/destroy"
      assert last_response.redirect?
    end
    assert_equal [rpayment.id], @event.rpayments.pluck(:id)
  end

  test "an organisation admin can't reach another event's revenue payment through their own event" do
    create_event(prices: [10])
    other_event = FactoryBot.create(:event)
    other_rpayment = other_event.rpayments.create!(account: other_event.account, amount: 10, currency: other_event.currency, role: 'organiser')
    sign_in_with_rack(@account)

    get "/e/#{@event.slug}/rpayments/#{other_rpayment.id}/edit"
    assert_equal 404, last_response.status
    post "/e/#{@event.slug}/rpayments/#{other_rpayment.id}/destroy"
    assert_equal 404, last_response.status
    assert Rpayment.find(other_rpayment.id)
  end

  # Check-in

  test "event admins and those with the event's check-in secret get the check-in scanner, and nobody else" do
    covers_route 'GET /e/:slug/check_in'
    create_event(prices: [0])
    check_in_secret = OpenSSL::HMAC.hexdigest('SHA256', ENV['CHECK_IN_SECRET'], "check_in:#{@event.id}")[0, 32]

    sign_in_with_rack(create_facilitator(@event))
    get "/e/#{@event.slug}/check_in"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "/e/#{@event.slug}/check_in?secret=#{check_in_secret}"

    # An assistant, signed out, with the link
    clear_cookies
    get "/e/#{@event.slug}/check_in"
    assert last_response.redirect?
    get "/e/#{@event.slug}/check_in", secret: 'wrong'
    assert_equal 403, last_response.status
    assert_includes last_response.body, 'your secret is wrong'
    get "/e/#{@event.slug}/check_in", secret: check_in_secret
    assert_equal 200, last_response.status
    # The secret is remembered for the rest of the session
    get "/e/#{@event.slug}/check_in"
    assert_equal 200, last_response.status

    # Another event's secret doesn't open this one
    other_event = FactoryBot.create(:event)
    clear_cookies
    get "/e/#{@event.slug}/check_in", secret: OpenSSL::HMAC.hexdigest('SHA256', ENV['CHECK_IN_SECRET'], "check_in:#{other_event.id}")[0, 32]
    assert_equal 403, last_response.status
  end

  # Event boosts Stripe webhook

  def checkout_completed_payload(session_id, payment_status: 'paid')
    { id: "evt_#{SecureRandom.hex(4)}", object: 'event', type: 'checkout.session.completed', data: { object: { id: session_id, object: 'checkout.session', payment_status: payment_status } } }.to_json
  end

  # Posts payload to the event boosts webhook as Stripe would, signed with secret
  def deliver_boosts_webhook(payload, secret: BOOSTS_SECRET)
    timestamp = Time.now
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret)
    with_env({ 'STRIPE_ENDPOINT_SECRET_EVENT_BOOSTS' => BOOSTS_SECRET }) do
      header 'Stripe-Signature', Stripe::Webhook::Signature.generate_header(timestamp, signature)
      header 'Content-Type', 'application/json'
      post '/event_boosts/stripe_webhook', payload
    end
  end

  def create_pending_boost
    create_event(prices: [0])
    FactoryBot.create(:account, admin: true)
    FactoryBot.create(:event_boost, :pending_payment, event: @event, session_id: "cs_#{SecureRandom.hex(4)}")
  end

  test "a paid checkout's webhook completes its boost once, telling the site's admins" do
    covers_route 'POST /event_boosts/stripe_webhook'
    event_boost = create_pending_boost
    payload = checkout_completed_payload(event_boost.session_id)

    deliver_boosts_webhook(payload)
    assert_equal 200, last_response.status
    assert event_boost.reload.payment_completed?
    # Stripe sends a webhook again if it isn't sure it arrived
    deliver_boosts_webhook(payload)
    assert_equal 200, last_response.status

    emails = emails_sent_by_jobs(ADMIN_NOTIFICATION_JOB)
    assert_equal ["[Event boost] #{event_boost.account.name} boosted #{@event.name}"], emails.map(&:subject_line)
  end

  test "the boosts webhook ignores a bad signature, an unpaid checkout and a session that's no boost's" do
    event_boost = create_pending_boost

    emails = recorded_emails do
      deliver_boosts_webhook(checkout_completed_payload(event_boost.session_id), secret: 'whsec_wrong')
      assert_equal 200, last_response.status

      with_env({ 'STRIPE_ENDPOINT_SECRET_EVENT_BOOSTS' => BOOSTS_SECRET }) do
        header 'Stripe-Signature', 'nonsense'
        post '/event_boosts/stripe_webhook', checkout_completed_payload(event_boost.session_id)
      end
      assert_equal 200, last_response.status

      deliver_boosts_webhook(checkout_completed_payload(event_boost.session_id, payment_status: 'unpaid'))
      assert_equal 200, last_response.status

      deliver_boosts_webhook(checkout_completed_payload('cs_unknown'))
      assert_equal 200, last_response.status
    end
    refute event_boost.reload.payment_completed?
    assert_empty emails
    assert_equal 0, Delayed::Job.and(handler: ADMIN_NOTIFICATION_JOB).count
  end
end
