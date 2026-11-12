require_relative '../test_config'
require_relative '../helpers/orders_helpers'

# What an event's admins can do to its orders and tickets (app/controllers/orders_admin.rb): restore deleted ones, transfer
# an order to another event, resend tickets, change a ticket's name or email and clear the answers to its questions, and
# that nobody else, an admin of another event among them, can do any of it
class OrdersAdminTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include OrdersHelpers

  # Queued Order#send_tickets jobs: other jobs' handlers can mention orders and tickets anywhere in the records they carry
  SEND_TICKETS_JOB = /Mongoid:Order\n.*method_name: :send_tickets_without_delay/m

  # Jobs aren't cleared between tests, so only this test's count
  setup do
    @earlier_job_ids = Delayed::Job.pluck(:id)
  end

  def send_tickets_jobs
    Delayed::Job.and(handler: SEND_TICKETS_JOB, :id.nin => @earlier_job_ids)
  end

  # The emails the Order#send_tickets jobs this test queued would send, running them
  def ticket_emails
    recorded_emails { send_tickets_jobs.each(&:invoke_job) }
  end

  def queued_ticket_emails
    send_tickets_jobs.count
  end

  # An order whose payment didn't complete, removed with its ticket, as a timed-out checkout is
  def create_deleted_incomplete_order
    create_complete_order_with_ticket
    @order.set(payment_completed: false)
    @ticket.set(payment_completed: false)
    @order.prevent_refund = true
    @order.destroy
  end

  # Someone who admins only this event, as its facilitator
  def create_facilitator(event)
    FactoryBot.create(:account).tap { |account| event.event_facilitations.create!(account: account) }
  end

  # An event of another organisation, with a complete order and ticket of its own
  def create_other_event_order
    other_event = FactoryBot.create(:event, prices: [0])
    order = other_event.orders.create!(account: FactoryBot.create(:account), currency: other_event.currency, value: 0, payment_completed: true)
    ticket = order.tickets.create!(event: other_event, account: order.account, ticket_type: other_event.ticket_types.first, price: 0)
    [other_event, order, ticket]
  end

  # Restoring

  test 'an admin restores and completes a deleted order, its tickets and sends them' do
    create_deleted_incomplete_order
    assert_nil Order.find(@order.id)
    sign_in(@account)

    visit "/e/#{@event.slug}/orders?deleted=1"
    click_button 'Actions'
    click_link 'Restore and complete'
    assert page.has_content? 'No orders found'

    order = Order.find(@order.id)
    assert order.payment_completed
    assert order.restored
    assert Ticket.find(@ticket.id).payment_completed
    assert_equal [[@attendee.email]], ticket_emails.map(&:recipients)
  end

  test 'a restored ticket counts against the event capacity' do
    create_complete_order_with_ticket
    @ticket.set(payment_completed: true)
    @event.update_attributes!(capacity: 1)
    @ticket.destroy
    assert_equal 1, Event.find(@event.id).places_remaining
    refute Event.find(@event.id).sold_out_cache
    sign_in(@account)

    visit "/e/#{@event.slug}/tickets?deleted=1"
    click_button 'Actions'
    click_link 'Restore'
    assert page.has_content? 'No tickets found'

    assert Ticket.find(@ticket.id)
    event = Event.find(@event.id)
    assert_equal 0, event.places_remaining
    assert event.sold_out_cache
  end

  test "an event admin can't restore another event's order or ticket through their own event" do
    create_complete_order
    facilitator = create_facilitator(@event)
    other_event, other_order, other_ticket = create_other_event_order
    other_order.prevent_refund = true
    other_order.destroy
    sign_in_with_rack(facilitator)

    # Their event has no deleted order or ticket with that id
    post "/e/#{@event.slug}/orders/#{other_order.id}/restore_and_complete"
    assert_equal 404, last_response.status
    post "/e/#{@event.slug}/tickets/#{other_ticket.id}/restore"
    assert_equal 404, last_response.status

    assert_nil Order.find(other_order.id)
    assert_nil Ticket.find(other_ticket.id)
    assert_equal 0, queued_ticket_emails

    # Nor through the other event, which they don't admin
    post "/e/#{other_event.slug}/orders/#{other_order.id}/restore_and_complete"
    assert last_response.redirect?
    post "/e/#{other_event.slug}/tickets/#{other_ticket.id}/restore"
    assert last_response.redirect?
    assert_nil Order.find(other_order.id)
    assert_nil Ticket.find(other_ticket.id)
  end

  # Transferring

  test 'an admin transfers an order and its tickets to another event of the organisation, freeing its place' do
    create_complete_order_with_ticket
    @ticket.set(payment_completed: true)
    @event.update_attributes!(capacity: 1)
    assert Event.find(@event.id).sold_out_cache
    create_event(prices: [0], as: :new_event)
    sign_in(@account)

    visit "/e/#{@event.slug}/orders"
    click_button 'Actions'
    click_link 'Transfer to another event'
    assert page.has_content? "Transfer #{@attendee.name}'s order"
    select @new_event.summary, from: 'order_event_id'
    click_button 'Update order'
    assert page.has_content? 'The order was transferred.'

    order = Order.find(@order.id)
    assert_equal @new_event.id, order.event_id
    assert order.transferred
    ticket = Ticket.find(@ticket.id)
    assert_equal @new_event.id, ticket.event_id
    assert ticket.transferred
    assert_nil ticket.ticket_type_id
    refute Event.find(@event.id).sold_out_cache
    assert_equal [[@attendee.email]], ticket_emails.map(&:recipients)
  end

  test "the transfer page offers only the organisation's other events the account admins" do
    create_complete_order
    facilitator = create_facilitator(@event)
    create_event(prices: [0], as: :admined_event)
    @admined_event.event_facilitations.create!(account: facilitator)
    create_event(prices: [0], as: :unadmined_event)
    sign_in(facilitator)

    visit "/orders/#{@order.id}/transfer"
    assert page.has_select? 'order_event_id', with_options: [@admined_event.summary]
    assert page.has_no_select? 'order_event_id', with_options: [@unadmined_event.summary]
    assert page.has_no_select? 'order_event_id', with_options: [@event.summary]
  end

  test "an order can't be transferred to an event its admin doesn't admin, or of another organisation" do
    create_complete_order_with_ticket
    facilitator = create_facilitator(@event)
    create_event(prices: [0], as: :unadmined_event)
    other_event, other_order, = create_other_event_order
    other_event.event_facilitations.create!(account: facilitator)
    sign_in_with_rack(facilitator)

    post "/orders/#{@order.id}/transfer", order: { event_id: @unadmined_event.id }
    assert_equal 403, last_response.status
    # Another organisation's event, even one they admin
    post "/orders/#{@order.id}/transfer", order: { event_id: other_event.id }
    assert_equal 404, last_response.status
    assert_equal @event.id, Order.find(@order.id).event_id
    assert_equal @event.id, Ticket.find(@ticket.id).event_id
    refute Order.find(@order.id).transferred

    # Nor can the admin of one event transfer another event's order, to theirs or any
    sign_in_with_rack(create_facilitator(@unadmined_event))
    get "/orders/#{@order.id}/transfer"
    assert last_response.redirect?
    post "/orders/#{@order.id}/transfer", order: { event_id: @unadmined_event.id }
    assert last_response.redirect?
    assert_equal @event.id, Order.find(@order.id).event_id
    assert_equal other_event.id, Order.find(other_order.id).event_id
    assert_equal 0, queued_ticket_emails
  end

  # Resending tickets

  test 'an admin resends the tickets for an order' do
    create_complete_order_with_ticket
    sign_in(@account)

    visit "/e/#{@event.slug}/orders"
    click_button 'Actions'
    click_link 'Resend order confirmation'
    assert page.has_content? 'The tickets for the order were resent.'

    emails = ticket_emails
    assert_equal [[@attendee.email]], emails.map(&:recipients)
    assert emails.first.finalized?
  end

  test "an event admin can't resend another event's tickets" do
    create_complete_order
    facilitator = create_facilitator(@event)
    _, other_order, = create_other_event_order
    sign_in_with_rack(facilitator)

    post "/orders/#{other_order.id}/send_tickets"
    assert last_response.redirect?
    assert_equal 0, queued_ticket_emails
  end

  # Editing tickets

  test "an admin changes a ticket's name and email" do
    create_complete_order_with_ticket
    sign_in(@account)

    visit "/e/#{@event.slug}/tickets"
    click_button 'Actions'
    click_link 'Change name or email'
    fill_in 'ticket_name', with: 'Ticket Holder'
    fill_in 'ticket_email', with: 'holder@example.com'
    click_button 'Update ticket'
    assert page.has_content? 'The ticket was updated.'

    ticket = Ticket.find(@ticket.id)
    assert_equal 'Ticket Holder', ticket.name
    assert_equal 'holder@example.com', ticket.email
  end

  test "an event admin can't see or change another event's ticket" do
    create_complete_order
    facilitator = create_facilitator(@event)
    _, _, other_ticket = create_other_event_order
    sign_in_with_rack(facilitator)

    get "/tickets/#{other_ticket.id}/edit"
    assert last_response.redirect?
    post "/tickets/#{other_ticket.id}/edit", ticket: { name: 'Hijacked', email: 'hijacked@example.com' }
    assert last_response.redirect?

    ticket = Ticket.find(other_ticket.id)
    refute_equal 'Hijacked', ticket.name
    refute_equal 'hijacked@example.com', ticket.email
  end

  # Clearing answers

  test "an admin clears the answers to the event's questions, on its orders only" do
    create_complete_order
    @order.set(answers: [['Dietary needs?', 'Vegan']])
    _, other_order, = create_other_event_order
    other_order.set(answers: [['Dietary needs?', 'None']])
    sign_in(@account)

    visit "/e/#{@event.slug}/orders"
    assert page.has_content? 'Vegan'
    find("a[href='/e/#{@event.slug}/orders/clear_answers']").click
    page.document.find('.popover').click_button 'Confirm'
    wait_until('the answers to be cleared') { Order.find(@order.id).answers.nil? }
    visit "/e/#{@event.slug}/orders"
    assert page.has_content? 'Displaying 1 order'
    assert page.has_no_content? 'Vegan'

    assert_equal [['Dietary needs?', 'None']], Order.find(other_order.id).answers
  end

  test "an event admin can't clear another event's answers" do
    create_complete_order
    facilitator = create_facilitator(@event)
    other_event, other_order, = create_other_event_order
    other_order.set(answers: [['Dietary needs?', 'None']])
    sign_in_with_rack(facilitator)

    post "/e/#{other_event.slug}/orders/clear_answers"
    assert last_response.redirect?
    assert_equal [['Dietary needs?', 'None']], Order.find(other_order.id).answers
  end
end
