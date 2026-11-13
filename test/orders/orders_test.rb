require_relative '../test_config'
require_relative '../helpers/checkout_webhook_helpers'
require_relative '../helpers/orders_helpers'

# Completing and cancelling orders, their emails and receipts, and the queries order pages run
class OrdersTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include CheckoutWebhookHelpers
  include OrdersHelpers

  # @event, with one £10 ticket type, and an order of one of its tickets whose payment hasn't completed
  def create_event_with_incomplete_order
    create_event(prices: [10])
    create_incomplete_order(@event)
  end

  def stub_completion_side_effects(order)
    counts = { tickets: 0, notifications: 0 }
    order.stub :send_tickets, proc { counts[:tickets] += 1 } do
      order.stub :create_order_notification, proc { counts[:notifications] += 1 } do
        yield counts
      end
    end
  end

  # The jobs queued to run a handle_asynchronously or .delay method
  def queued_jobs(method_name)
    Delayed::Job.and(handler: /\b#{method_name}(_without_delay)?\b/)
  end

  # The emails the jobs queued to run a method send
  def emails_from_jobs(method_name)
    recorded_emails { queued_jobs(method_name).each(&:invoke_job) }
  end

  test 'complete_or_restore completes an order only once' do
    order = create_event_with_incomplete_order

    stub_completion_side_effects(order) do |counts|
      order.complete_or_restore
      order.complete_or_restore
      assert_equal 1, counts[:tickets]
      assert_equal 1, counts[:notifications]
    end

    assert order.reload.payment_completed?
  end

  test 'complete_or_restore clears completing_at after an exception' do
    order = create_event_with_incomplete_order
    order.stub :payment_completed!, proc { raise 'boom' } do
      assert_raises(RuntimeError) { order.complete_or_restore }
    end

    assert_nil order.reload.completing_at
    refute order.payment_completed?
  end

  test 'free orders with a donation to Dandelion get a receipt PDF' do
    covers 'events/free-order-donation-receipt@388e58'
    create_complete_order_with_ticket
    @order.set(application_fee_paid_to_dandelion: true)
    refute @order.donation_receipt?

    @order.donations.create!(account: @attendee, event: @event, amount: 10)
    assert @order.donation_receipt?
    assert @order.donation_receipt_pdf.render.start_with?('%PDF')

    @order.set(application_fee_paid_to_dandelion: false)
    refute @order.donation_receipt?
  end

  test 'paid orders with a donation to Dandelion do not get a receipt PDF' do
    covers 'events/free-order-donation-receipt@388e58'
    create_complete_order
    @order.set(application_fee_paid_to_dandelion: true)
    @order.tickets.create!(event: @event, account: @attendee, ticket_type: @event.ticket_types.first, price: 5)
    @order.donations.create!(account: @attendee, event: @event, amount: 10)
    refute @order.donation_receipt?
  end

  def add_order_with_ticket(event)
    attendee = FactoryBot.create(:account)
    order = event.orders.create!(account: attendee, currency: event.currency, value: 10, payment_completed: true)
    order.tickets.create!(event: event, account: attendee, ticket_type: event.ticket_types.first, price: 10)
    attendee
  end

  # The queries a request runs, as [command, collection] pairs
  def queries_during
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |e| commands << [e.command_name, e.command.values.first] }
    subscriber.define_singleton_method(:succeeded) { |_| nil }
    subscriber.define_singleton_method(:failed) { |_| nil }
    Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    yield
    commands
  ensure
    Mongoid.default_client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber) if subscriber
  end

  test "the organisation orders page shows each event's revenue, reading every event's tickets at once" do
    create_event(prices: [10])
    sign_in_with_rack(@account)
    sell = lambda do |event, price|
      order = event.orders.create!(account: FactoryBot.create(:account), currency: event.currency, value: price, payment_completed: true)
      order.tickets.create!(event: event, account: order.account, ticket_type: event.ticket_types.first, price: price, payment_completed: true)
    end
    # An event's column in its orders' rows: its name, countdown, progress and revenue
    event_cell = ->(event) { last_response.body[%r{<td>\s*<a href="/e/#{event.slug}">.*?</td>}m] }
    ticket_queries = lambda do
      queries = queries_during { get "/o/#{@organisation.slug}/orders" }
      assert_equal 200, last_response.status
      queries.count(%w[find tickets])
    end

    sell.call(@event, 10)
    one_event = ticket_queries.call
    assert_includes event_cell.call(@event), '£10'

    others = [25, 40].each_with_index.map do |price, i|
      create_event(prices: [price], as: :"event#{i}").tap { |event| 2.times { sell.call(event, price) } }
    end
    assert_equal one_event, ticket_queries.call
    assert_includes event_cell.call(@event), '£10'
    assert_includes event_cell.call(others[0]), '£50'
    assert_includes event_cell.call(others[1]), '£80'
  end

  test 'event tickets and orders pages run the same queries however many orders there are' do
    covers_route 'GET /e/:slug/orders'
    covers_route 'GET /e/:slug/tickets'
    create_event(prices: [10])
    @event.ticket_types.first.update!(quantity: 10)
    attendees = Array.new(2) { add_order_with_ticket(@event) }
    sign_in_with_rack(@account)

    counts = lambda do |path|
      queries = queries_during { get path }
      assert_equal 200, last_response.status
      { events: queries.count(%w[find events]), tickets: queries.count(%w[find tickets]), orders: queries.count(%w[find orders]) }
    end

    tickets_before = counts.call("/e/#{@event.slug}/tickets")
    # Each table loads its page of records once, not again for each map, each and pagination_details
    assert_operator tickets_before[:tickets], :<=, 2
    orders_before = counts.call("/e/#{@event.slug}/orders")
    # The table's page, its accounts and booking questions, and the stats row's check for incomplete orders
    assert_operator orders_before[:orders], :<=, 4
    get "/e/#{@event.slug}/tickets"
    attendees.each { |attendee| assert_includes last_response.body, attendee.name }
    assert_includes last_response.body, 'Displaying <b>all 2</b> tickets'

    3.times { add_order_with_ticket(@event) }

    assert_equal tickets_before, counts.call("/e/#{@event.slug}/tickets")
    assert_includes last_response.body, 'Displaying <b>all 5</b> tickets'
    assert_equal orders_before, counts.call("/e/#{@event.slug}/orders")
    assert_includes last_response.body, 'Displaying <b>all 5</b> orders'
  end

  def create_complimentary_ticket(price: nil)
    create_event(prices: [10])
    @attendee = FactoryBot.create(:account)
    @attendee.tickets.create!(event: @event, ticket_type: @event.ticket_types.first, price: price, complimentary: true)
  end

  test 'complimentary tickets can be cancelled by their account' do
    covers 'events/attendees-cancel-free-rsvps@2edb4c'
    ticket = create_complimentary_ticket
    assert ticket.cancellable?
    sign_in(@attendee)

    visit "/e/#{@event.slug}"
    assert page.has_link? 'Cancel RSVP', href: "/tickets/#{ticket.id}/destroy"

    # As the Cancel your RSVP link in their ticket email does
    visit "/tickets/#{ticket.id}/confirm_cancel"
    click_button 'Yes, cancel my RSVP'
    assert page.has_current_path? "/e/#{@event.slug}"
    assert_nil Ticket.find(ticket.id)
  end

  test 'complimentary tickets cannot be cancelled by another account' do
    covers 'events/attendees-cancel-free-rsvps@2edb4c'
    covers_route 'GET /tickets/:id/confirm_cancel'
    covers_route 'POST /tickets/:id/destroy'
    ticket = create_complimentary_ticket
    sign_in_with_rack(FactoryBot.create(:account))

    get "/tickets/#{ticket.id}/confirm_cancel"
    assert_equal 403, last_response.status
    post "/tickets/#{ticket.id}/destroy"
    assert_equal 403, last_response.status
    assert Ticket.find(ticket.id)
  end

  test 'priced complimentary tickets and tickets in orders cannot be cancelled as tickets' do
    covers 'events/paid-orders-not-cancellable@9106dd'
    ticket = create_complimentary_ticket(price: 10)
    refute ticket.cancellable?
    sign_in_with_rack(@attendee)
    post "/tickets/#{ticket.id}/destroy"
    assert_equal 403, last_response.status

    create_complete_order_with_ticket
    refute @ticket.cancellable?
  end

  test 'free orders can be cancelled by their account, which emails them and tells the waitlist a place is available' do
    covers 'events/attendees-cancel-free-rsvps@2edb4c', 'events/cancellation-emails-and-waitlist@ddd281'
    covers_route 'POST /orders/:id/destroy'
    Delayed::Job.delete_all
    create_complete_order_with_ticket
    @event.set(capacity: 1)
    @event.refresh_sold_out_cache_and_notify_waitlist
    Waitship.create!(event: @event, account: FactoryBot.create(:account))
    assert Event.find(@event.id).sold_out_cache
    sign_in(@attendee)

    visit "/e/#{@event.slug}"
    assert page.has_content? 'Your orders'
    click_link_and_confirm 'Cancel RSVP'
    wait_until('order not cancelled') { queued_jobs(:send_rsvp_cancelled_email).exists? && queued_jobs(:send_waitlist_tickets_available).exists? }
    assert_nil Order.find(@order.id)
    assert_nil Ticket.find(@ticket.id)

    assert_equal [[@attendee.email]], emails_from_jobs(:send_rsvp_cancelled_email).map(&:recipients)
    assert_equal 1, queued_jobs(:send_waitlist_tickets_available).count
  end

  test 'cancelling a complimentary ticket emails its account to confirm' do
    covers 'events/cancellation-emails-and-waitlist@ddd281'
    Delayed::Job.delete_all
    ticket = create_complimentary_ticket
    sign_in(@attendee)

    visit "/e/#{@event.slug}"
    assert page.has_content? 'Your tickets'
    click_link_and_confirm 'Cancel RSVP'
    wait_until('ticket not cancelled') { queued_jobs(:send_rsvp_cancelled_email).exists? }
    assert_nil Ticket.find(ticket.id)
    assert_equal [[@attendee.email]], emails_from_jobs(:send_rsvp_cancelled_email).map(&:recipients)
  end

  test 'the Cancel your RSVP links in ticket and reminder emails cancel a free order' do
    covers 'events/attendees-cancel-free-rsvps@2edb4c'
    covers_route 'GET /orders/:id/confirm_cancel'
    create_complete_order_with_ticket
    html = EmailHelper.html(:tickets, event: @event, order: @order, account: @attendee, tickets_table: '', header_image_url: nil)
    assert_includes html, "/orders/#{@order.id}/confirm_cancel?link_token=%recipient.token%"
    @event.set(reminder_hours_before: 24)

    reminder = recorded_emails { @event.send_reminders_without_delay(@attendee.id) }.find { |email| email.recipients.any? }
    assert_includes reminder.html, '%recipient.cancel_rsvp_url%'
    cancel_url = URI(reminder.variables[@attendee.email]['cancel_rsvp_url'])
    assert_equal "/orders/#{@order.id}/confirm_cancel", cancel_url.path

    # Not signed in: the link's token signs them in
    visit cancel_url.request_uri
    click_button 'Yes, cancel my RSVP'
    assert page.has_current_path? "/e/#{@event.slug}"
    assert_nil Order.find(@order.id)
  end

  test 'paid orders and tickets cannot be cancelled or refunded by their attendee' do
    covers 'events/paid-orders-not-cancellable@9106dd', 'events/attendees-cannot-refund@1c589f'
    covers_route 'POST /e/:slug/tickets/:ticket_id/refund_and_destroy'
    create_event(prices: [10])
    order = create_paid_order(@event)
    ticket = order.tickets.create!(event: @event, account: order.account, ticket_type: @event.ticket_types.first, price: 10,
                                   payment_completed: true, payment_intent: order.payment_intent)
    sign_in_with_rack(order.account)

    get "/e/#{@event.slug}"
    refute_includes last_response.body, "/orders/#{order.id}/destroy"
    with_stubbed_stripe_refunds do |refunds|
      get "/orders/#{order.id}/confirm_cancel"
      assert_equal 403, last_response.status
      post "/orders/#{order.id}/destroy"
      assert_equal 403, last_response.status
      post "/tickets/#{ticket.id}/destroy"
      assert_equal 403, last_response.status
      post "/e/#{@event.slug}/orders/#{order.id}/refund_and_destroy"
      post "/e/#{@event.slug}/tickets/#{ticket.id}/refund_and_destroy"
      assert_empty refunds
    end
    assert Order.find(order.id)
    assert Ticket.find(ticket.id)
  end

  test 'order notifications are emailed to facilitators only when the event sends them' do
    covers 'events/order-notification-emails@73c132'
    Delayed::Job.delete_all
    order = create_event_with_incomplete_order
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    @event.set(send_order_notifications: true)

    order.complete_or_restore
    # The event's creator is a facilitator too
    assert_equal [[@account.email, facilitator.email].sort], (emails_from_jobs(:send_notification).map { |email| email.recipients.sort })
    refute_includes @event.event_facilitators, order.account

    Delayed::Job.delete_all
    order = create_event_with_incomplete_order
    @event.set(send_order_notifications: false)
    order.complete_or_restore
    assert order.reload.payment_completed
    assert_equal 0, queued_jobs(:send_notification).count
  end

  test 'only the orderer gets the order confirmation unless the event sends it to other ticketholders' do
    covers 'events/ticketholder-confirmation-setting@b8610e'
    covers_route 'GET /e/:slug/orders/:order_id/ticketholders/:ticket_id/email'
    covers_route 'POST /e/:slug/orders/:order_id/ticketholders/:ticket_id/email'
    Delayed::Job.delete_all
    create_complete_order_with_ticket
    @ticket.set(email: 'holder@example.com')
    assert_equal [[@attendee.email]], recorded_emails { @order.send_tickets_without_delay }.map(&:recipients)

    @ticket.set(email: nil)
    visit "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert page.has_content? 'Thanks for booking'
    change_ticketholder_field 'email', 'holder@example.com'
    wait_until('email not saved') { @ticket.reload.email == 'holder@example.com' }

    @event.set(send_ticketholder_confirmation: true)
    visit "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert page.has_content? 'receive the order confirmation'
    change_ticketholder_field 'email', 'friend@example.com'
    wait_until('order confirmation not sent') { queued_jobs(:send_ticket).exists? }
    # Only for the second email, as the first was entered while the event didn't send it
    assert_equal [['friend@example.com']], emails_from_jobs(:send_ticket).map(&:recipients)
  end

  test 'the ticket keeps its token, which its PDF holds, when the ticketholder changes' do
    covers 'events/ticket-pdf-works-after-transfer@a22930'
    create_complete_order_with_ticket
    token = @ticket.public_id

    visit "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert page.has_content? 'Thanks for booking'
    change_ticketholder_field 'name', 'New Holder'
    wait_until('name not saved') { @ticket.reload.name == 'New Holder' }
    change_ticketholder_field 'email', 'newholder@example.com'
    wait_until('email not saved') { @ticket.reload.email == 'newholder@example.com' }
    assert_equal token, @ticket.public_id
  end

  test 'the original ticket PDF still checks in after the ticketholder changes' do
    covers 'events/ticket-pdf-works-after-transfer@a22930'
    covers_route 'POST /e/:slug/check_in/:ticket_id'
    create_complete_order_with_ticket
    token = @ticket.public_id
    @ticket.set(name: 'New Holder', email: 'newholder@example.com')

    secret = OpenSSL::HMAC.hexdigest('SHA256', ENV['CHECK_IN_SECRET'], "check_in:#{@event.id}")[0, 32]
    post "/e/#{@event.slug}/check_in/#{token}", checked_in: true, secret: secret
    assert_equal 200, last_response.status
    assert @ticket.reload.checked_in
  end
end
