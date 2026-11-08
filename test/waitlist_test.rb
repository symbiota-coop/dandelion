require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class WaitlistTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # Stands in for Mailgun::BatchMessage, keeping who an email would go to
  class RecordedEmail
    attr_reader :recipients

    def initialize
      @recipients = []
    end

    def add_recipient(_type, email, _variables)
      @recipients << email
    end

    def from(*); end
    def subject(*); end
    def body_html(*); end
    def reply_to(*); end
    def finalize; end
  end

  # Runs the queued jobs whose handler matches, returning the emails they would send
  def emails_sent_by_jobs(handler)
    emails = []
    Mailgun::BatchMessage.stub :new, proc { RecordedEmail.new.tap { |email| emails << email } } do
      Delayed::Job.and(handler: handler).each(&:invoke_job)
    end
    emails
  end

  def create_facilitated_event(**event_options)
    create_full_event_hierarchy(event_options: { prices: [10], send_order_notifications: true, **event_options })
    @facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: @facilitator)
  end

  def create_ticket_type_waitlist_event
    create_full_event_hierarchy(
      event_options: {
        prices: [10],
        allow_ticket_type_waitlists: true,
        suggested_donation: 0
      }
    )
    @ticket_type = @event.ticket_types.first
  end

  def sell_out_ticket_type
    @ticket_type.set(quantity: 0)
    @event.refresh_sold_out_cache_and_notify_waitlist
    @event.reload
  end

  test 'joining waitlist on sold-out event' do
    covers 'events/waitlist-on-sell-out@4409be'
    create_full_event_hierarchy(event_options: { prices: [10] })
    # Sell out the event by setting quantity to 0
    @event.ticket_types.first.set(quantity: 0)
    @event.refresh_sold_out_cache_and_notify_waitlist

    visit "/e/#{@event.slug}"
    assert page.has_content?('This event is sold out'), 'Should show sold out message'
    assert page.has_content?('Join the waitlist'), 'Should show waitlist option'

    fill_in 'waitship_name', with: 'Waitlist User'
    fill_in 'waitship_email', with: 'waitlist@example.com'

    # Mock recaptcha for testing
    execute_script "window.grecaptcha = { getResponse: function() { return 'test-token'; } }"

    click_button 'Submit'

    assert page.has_current_path?(/added_to_waitlist=true/, url: true), 'Should redirect with waitlist confirmation'

    waitlist_account = Account.find_by(email: 'waitlist@example.com')
    assert waitlist_account.present?, 'Account should be created'
    assert @event.waitships.find_by(account: waitlist_account), 'Waitship should exist'
    assert_associated(@organisation, waitlist_account, :organisationships)
    assert_associated(@activity, waitlist_account, :activityships)
    assert_associated(@local_group, waitlist_account, :local_groupships)
  end

  test 'waitship removed when ticket payment completed' do
    create_event(prices: [10])
    buyer = FactoryBot.create(:account)

    # Add user to waitlist (bypass callbacks by using save without validation)
    waitship = Waitship.new(account: buyer, event: @event)
    waitship.save(validate: false)
    assert @event.waitships.find_by(account: buyer), 'Waitship should exist initially'

    # Create a ticket directly
    ticket_type = @event.ticket_types.first
    ticket = Ticket.create!(
      event: @event,
      account: buyer,
      ticket_type: ticket_type,
      price: 10
    )

    ticket.payment_completed!

    assert_nil @event.reload.waitships.find_by(account: buyer),
               'Waitship should be removed after ticket payment completed'
  end

  test 'cannot join waitlist twice' do
    create_event(prices: [10])
    buyer = FactoryBot.create(:account)

    waitship1 = Waitship.create!(account: buyer, event: @event)
    assert waitship1.persisted?, 'First waitship should be created'

    waitship2 = Waitship.new(account: buyer, event: @event)
    assert_not waitship2.valid?, "Duplicate waitship should not be valid. Errors: #{waitship2.errors.full_messages}"
    assert waitship2.errors[:account_id].present? || waitship2.errors[:account].present?,
           "Should have uniqueness error. All errors: #{waitship2.errors.full_messages}"
  end

  test 'waitlist with activity having non-open privacy does not create activityship' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'secret')
    create_event(activity: activity, prices: [10])
    buyer = FactoryBot.create(:account)
    @event.waitships.create(account: buyer)

    assert_nil activity.activityships.find_by(account: buyer),
               'Should not create activityship for secret activity'

    assert @organisation.organisationships.find_by(account: buyer),
           'Should still create organisationship'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Ticket type waitlists
  # ═══════════════════════════════════════════════════════════════════════════

  test 'joining ticket type waitlist creates waitship for selected ticket type' do
    covers 'events/ticket-type-waitlists@ac1e0a', 'events/ticket-type-waitlist-join-button@83f96f'
    create_ticket_type_waitlist_event
    sell_out_ticket_type

    visit "/e/#{@event.slug}"
    find('button.join-ticket-type-waitlist').click

    account = FactoryBot.build_stubbed(:account)

    fill_in 'ticket-type-waitlist-name', with: account.name
    fill_in 'ticket-type-waitlist-email', with: account.email
    execute_script "window.grecaptcha = { getResponse: function() { return 'test-token'; }, reset: function() {} }"
    within '#ticket-type-waitlist-modal' do
      click_button 'Join waitlist'
    end

    assert page.has_content?('Joined waitlist!'), 'Successful join should update the ticket type row'
    waitlist_account = Account.find_by(email: account.email)
    assert waitlist_account.present?, 'Account should be created'
    assert @ticket_type.ticket_type_waitships.find_by(account: waitlist_account),
           'Ticket type waitship should be created for the selected ticket type'
    assert_nil @event.waitships.find_by(account: waitlist_account),
               'Joining a ticket type waitlist should not create an event waitship'
  end

  test 'sales ended ticket type uses generic sold out flow instead of ticket type waitlist controls' do
    covers 'events/ticket-type-waitlists@ac1e0a'
    create_ticket_type_waitlist_event
    @ticket_type.set(quantity: 0, sales_end: 1.hour.ago)
    @event.refresh_sold_out_cache_and_notify_waitlist
    @event.reload

    refute @event.ticket_type_waitlists_available?,
           'Ticket type waitlists should not be available once sales have ended'

    visit "/e/#{@event.slug}"

    assert page.has_content?('Sales have ended for this event')
    assert page.has_no_css?('button.join-ticket-type-waitlist'),
           'Sales-ended ticket types should not render per-ticket waitlist buttons'
  end

  test 'ticket type waitship is removed when matching ticket payment completes' do
    create_ticket_type_waitlist_event
    sell_out_ticket_type
    account = FactoryBot.create(:account)

    TicketTypeWaitship.create!(ticket_type: @ticket_type, account: account)
    assert @ticket_type.ticket_type_waitships.find_by(account: account),
           'Ticket type waitship should exist before purchase'

    @ticket_type.set(quantity: 1)
    ticket = Ticket.create!(
      event: @event,
      account: account,
      ticket_type: @ticket_type,
      price: @ticket_type.price
    )
    ticket.payment_completed!

    assert_nil @ticket_type.reload.ticket_type_waitships.find_by(account: account),
               'Ticket type waitship should be removed after purchase'
  end

  test 'ticket type waitlist notification triggered when tickets become available' do
    covers 'events/ticket-type-waitlist-emailed@e84fc2', 'integrations/waitlist-emailed-when-available@af5f30'
    Delayed::Job.delete_all if defined?(Delayed::Job)
    create_ticket_type_waitlist_event
    sell_out_ticket_type
    account = FactoryBot.create(:account)

    TicketTypeWaitship.create!(ticket_type: @ticket_type, account: account)
    assert @ticket_type.reload.sold_out?, 'Ticket type should be sold out'
    assert @ticket_type.sold_out_cache?, 'Ticket type sold-out cache should be primed'

    @ticket_type.set(quantity: 1)
    @event.refresh_sold_out_cache_and_notify_waitlist

    assert_not @ticket_type.reload.sold_out?, 'Ticket type should no longer be sold out'
    assert_equal 1, Delayed::Job.and(handler: /send_ticket_type_waitlist_tickets_available/).count,
                 'Ticket type waitlist notification should be queued'
  end

  test "the waitlist forms refuse a waitlist that isn't open, without making an account" do
    covers 'events/waitlist-on-sell-out@4409be', 'events/ticket-type-waitlists@ac1e0a'
    create_ticket_type_waitlist_event

    header 'Accept', 'application/json'
    post "/e/#{@event.slug}/ticket_type_waitships", ticket_type_id: @ticket_type.id.to_s, name: 'Early Bird', email: 'early@example.com'
    assert_equal 400, last_response.status
    assert_equal 'This ticket type is not sold out.', JSON.parse(last_response.body)['error']

    post "/e/#{@event.slug}/waitship/new", waitship: { name: 'Early Bird', email: 'early@example.com' }
    assert_equal 302, last_response.status
    assert_equal 0, @event.waitships.count
    assert_nil Account.find_by(email: 'early@example.com')
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Notifications
  # ═══════════════════════════════════════════════════════════════════════════

  test 'facilitators are emailed when someone joins the waitlist if order notifications are on' do
    covers 'events/waitlist-facilitators-emailed@4c7b4f'
    create_facilitated_event
    Delayed::Job.delete_all
    @event.waitships.create!(account: FactoryBot.create(:account))

    emails = emails_sent_by_jobs(/Waitship.*send_notification/m)
    assert_equal 1, emails.length
    assert_equal @event.event_facilitators.pluck(:email).sort, emails.first.recipients.sort
    assert_includes emails.first.recipients, @facilitator.email

    Delayed::Job.delete_all
    @event.set(send_order_notifications: false)
    @event.waitships.create!(account: FactoryBot.create(:account))
    assert_equal 0, Delayed::Job.and(handler: /send_notification/).count
  end

  test 'facilitators are emailed when someone joins a ticket type waitlist if order notifications are on' do
    covers 'events/ticket-type-waitlist-facilitators-emailed@55ce1c'
    create_facilitated_event(allow_ticket_type_waitlists: true, suggested_donation: 0)
    @ticket_type = @event.ticket_types.first
    sell_out_ticket_type
    Delayed::Job.delete_all
    TicketTypeWaitship.create!(ticket_type: @ticket_type, account: FactoryBot.create(:account))

    emails = emails_sent_by_jobs(/TicketTypeWaitship.*send_notification/m)
    assert_equal 1, emails.length
    assert_equal @event.event_facilitators.pluck(:email).sort, emails.first.recipients.sort
    assert_includes emails.first.recipients, @facilitator.email

    Delayed::Job.delete_all
    @event.set(send_order_notifications: false)
    TicketTypeWaitship.create!(ticket_type: @ticket_type, account: FactoryBot.create(:account))
    assert_equal 0, Delayed::Job.and(handler: /send_notification/).count
  end

  def create_sold_out_event_with_waitlist
    create_event(prices: [0])
    @ticket_type = @event.ticket_types.first
    @ticket_type.set(quantity: 1)
    @order = Order.create!(event: @event, account: FactoryBot.create(:account), value: 0, payment_completed: true, currency: 'GBP')
    @ticket_type.tickets.create!(event: @event, order: @order, account: @order.account, payment_completed: true, price: 0)
    assert Event.find(@event.id).sold_out_cache
    @waiter = FactoryBot.create(:account)
    @event.waitships.create!(account: @waiter)
    Delayed::Job.delete_all
  end

  test 'releasing more tickets at a sold-out event emails the waitlist' do
    covers 'events/waitlist-emailed-when-tickets-available@a5c6b3'
    create_sold_out_event_with_waitlist

    @ticket_type.update!(quantity: 2)

    emails = emails_sent_by_jobs(/send_waitlist_tickets_available/)
    assert_equal [[@waiter.email]], emails.map(&:recipients)
  end

  test 'cancelling an order at a sold-out event emails the waitlist' do
    covers 'events/waitlist-emailed-when-tickets-available@a5c6b3'
    create_sold_out_event_with_waitlist
    sign_in(@account)

    visit "/e/#{@event.slug}/orders"
    click_button 'Actions'
    click_link 'Remove order'
    # The popover hangs off the page, outside any within block
    page.document.find('.popover').click_button 'Remove order'
    assert page.has_content? 'No orders found'
    assert_nil Order.find(@order.id)

    emails = emails_sent_by_jobs(/send_waitlist_tickets_available/)
    assert_equal [[@waiter.email]], emails.map(&:recipients)
  end

  test 'ticket type waitlists are unavailable when the setting is off or the event treats sales as closed' do
    covers 'events/ticket-type-waitlists@ac1e0a'
    create_ticket_type_waitlist_event
    sell_out_ticket_type
    assert @event.ticket_type_waitlists_available?

    @event.set(allow_ticket_type_waitlists: false)
    refute Event.find(@event.id).ticket_type_waitlists_available?
    waitship = TicketTypeWaitship.new(ticket_type: TicketType.find(@ticket_type.id), account: FactoryBot.create(:account))
    refute waitship.valid?
    assert_includes waitship.errors.full_messages, 'Ticket type waitlists are not enabled for this event.'

    @event.set(allow_ticket_type_waitlists: true, no_sales_after_end_time: true, start_time: 2.hours.ago, end_time: 1.hour.ago)
    assert Event.find(@event.id).sales_closed_due_to_event_end?
    refute Event.find(@event.id).ticket_type_waitlists_available?
    waitship = TicketTypeWaitship.new(ticket_type: TicketType.find(@ticket_type.id), account: FactoryBot.create(:account))
    refute waitship.valid?
    assert_includes waitship.errors.full_messages, 'Sales are closed for this ticket.'
  end

  test 'the Ticket type waitlists menu item appears once someone has joined one' do
    covers 'events/ticket-type-waitlists-menu-item@66c29c'
    create_ticket_type_waitlist_event
    sell_out_ticket_type
    sign_in_with_rack(@account)

    get "/e/#{@event.slug}/discount_codes"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "/e/#{@event.slug}/discount_codes"
    refute_includes last_response.body, "/e/#{@event.slug}/ticket_type_waitlists"

    TicketTypeWaitship.create!(ticket_type: @ticket_type, account: FactoryBot.create(:account))
    get "/e/#{@event.slug}/discount_codes"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Ticket type waitlists'
    assert_includes last_response.body, "/e/#{@event.slug}/ticket_type_waitlists"
  end

end

