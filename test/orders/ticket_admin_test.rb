require_relative '../test_config'
require_relative '../helpers/orders_helpers'

# What an event's admins can do to a single ticket from its tickets page (app/controllers/orders_admin.rb): change its
# price or ticket type and resend it, and that nobody else, an admin of another event among them, can. Also the old link
# to cancel a free order
class OrdersTicketAdminTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include OrdersHelpers

  SEND_TICKET_JOB = /method_name: :send_ticket_without_delay/

  # A paid order of one £10 ticket
  def create_paid_ticket
    create_event(prices: [10])
    @attendee = FactoryBot.create(:account)
    @order = @event.orders.create!(account: @attendee, currency: @event.currency, value: 10, payment_completed: true)
    @ticket = @order.tickets.create!(event: @event, account: @attendee, ticket_type: @event.ticket_types.first, price: 10, payment_completed: true)
  end

  # An event of another organisation, with a ticket of its own, and an admin of it
  def create_other_event_ticket
    other_event = FactoryBot.create(:event, prices: [5])
    order = other_event.orders.create!(account: FactoryBot.create(:account), currency: other_event.currency, value: 5, payment_completed: true)
    ticket = order.tickets.create!(event: other_event, account: order.account, ticket_type: other_event.ticket_types.first, price: 5, payment_completed: true)
    [other_event, ticket, create_facilitator(other_event)]
  end

  # Price

  test "an event admin changes a ticket's price from the tickets page, leaving its order's value as it was" do
    covers_route 'GET /tickets/:id/price'
    covers_route 'POST /tickets/:id/price'
    create_paid_ticket
    sign_in(create_facilitator(@event))

    visit "/e/#{@event.slug}/tickets"
    price_cell = "[data-pagelet-url='/tickets/#{@ticket.id}/price']"
    within(price_cell) do
      click_link '£10'
      fill_in 'price', with: '7.5'
      find_field('price').send_keys(:tab)
    end
    wait_until('price not saved') { @ticket.reload.discounted_price.to_s == '7.5' }
    # The cell reloads from /tickets/:id/price with the new price
    assert page.has_css?("#{price_cell} a", text: '£7.50')
    assert_in_delta 10, @order.reload.value
  end

  test "someone who isn't an admin of a ticket's event can't see or change its price" do
    create_paid_ticket
    _, other_ticket, other_admin = create_other_event_ticket

    [other_admin, @attendee].each do |account|
      sign_in_with_rack(account)
      get "/tickets/#{@ticket.id}/price", {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
      assert_equal 403, last_response.status
      post "/tickets/#{@ticket.id}/price", price: 0
      assert last_response.redirect?
    end
    assert_in_delta 10, @ticket.reload.discounted_price
    assert_in_delta 5, other_ticket.reload.discounted_price

    post "/tickets/#{BSON::ObjectId.new}/price", price: 0
    assert_equal 404, last_response.status
  end

  # Ticket type

  test "an event admin moves a ticket to another ticket type, and the event's places follow it" do
    covers_route 'GET /tickets/:id/ticket_type'
    covers_route 'POST /tickets/:id/ticket_type'
    create_paid_ticket
    @event.ticket_types.first.update_attributes!(name: 'Hidden place', hidden: true)
    last_place = FactoryBot.create(:ticket_type, event: @event, name: 'Last place', price_or_range: 10, quantity: 1)
    @event.refresh_sold_out_cache_and_notify_waitlist
    refute Event.find(@event.id).sold_out_cache
    sign_in(@account)

    visit "/e/#{@event.slug}/tickets"
    type_cell = "[data-pagelet-url='/tickets/#{@ticket.id}/ticket_type']"
    within(type_cell) do
      click_link 'Hidden place'
      select 'Last place', from: 'ticket_type_id'
    end
    wait_until('ticket type not saved') { @ticket.reload.ticket_type_id == last_place.id }
    # The cell reloads from /tickets/:id/ticket_type with the new ticket type
    assert page.has_css?("#{type_cell} a", text: 'Last place')
    assert_equal 0, TicketType.find(last_place.id).remaining
    # The only ticket type on sale is now full
    assert Event.find(@event.id).sold_out_cache
  end

  test "a ticket can't be moved to another event's ticket type, nor by someone who isn't an admin of its event" do
    create_paid_ticket
    other_event, other_ticket, other_admin = create_other_event_ticket
    ticket_type_id = @ticket.ticket_type_id

    sign_in_with_rack(@account)
    post "/tickets/#{@ticket.id}/ticket_type", ticket_type_id: other_event.ticket_types.first.id
    assert_equal 404, last_response.status
    assert_equal ticket_type_id, @ticket.reload.ticket_type_id

    sign_in_with_rack(other_admin)
    get "/tickets/#{@ticket.id}/ticket_type", {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert_equal 403, last_response.status
    post "/tickets/#{@ticket.id}/ticket_type", ticket_type_id: other_event.ticket_types.first.id
    assert last_response.redirect?
    assert_equal ticket_type_id, @ticket.reload.ticket_type_id
    assert_equal other_event.ticket_types.first.id, other_ticket.reload.ticket_type_id
  end

  # Resending

  test "an event admin resends a single ticket to its holder, and it stays in its order" do
    covers_route 'POST /tickets/:id/send_ticket'
    create_paid_ticket
    sign_in(create_facilitator(@event))

    visit "/e/#{@event.slug}/tickets"
    click_button 'Actions'
    click_link 'Resend single ticket'
    assert page.has_content?('The ticket was resent.')

    emails = emails_sent_by_jobs(SEND_TICKET_JOB)
    assert_equal [[@attendee.email]], emails.map(&:recipients)
    assert_equal ["Ticket to #{@event.name}"], emails.map(&:subject_line)
    assert_equal @order.id, Ticket.find(@ticket.id).order_id
  end

  test "someone who isn't an admin of a ticket's event can't resend it" do
    create_paid_ticket
    _, _, other_admin = create_other_event_ticket

    [other_admin, @attendee].each do |account|
      sign_in_with_rack(account)
      post "/tickets/#{@ticket.id}/send_ticket"
      assert last_response.redirect?
    end
    assert_equal 0, Delayed::Job.and(handler: SEND_TICKET_JOB).count
  end

  # Cancelling a free order

  test 'the old link to cancel a free order goes on to the cancel page, keeping its query string' do
    covers_route 'GET /orders/:id/confirm_destroy'
    create_complete_order
    order_path = "/orders/#{@order.id}"

    get "#{order_path}/confirm_destroy", utm_source: 'email'
    assert last_response.redirect?
    assert_equal "#{order_path}/confirm_cancel?utm_source=email", URI(last_response.location).request_uri

    get "#{order_path}/confirm_destroy"
    assert_equal "#{order_path}/confirm_cancel", URI(last_response.location).request_uri

    # Where it leads is the buyer's alone
    sign_in_with_rack(FactoryBot.create(:account))
    get "#{order_path}/confirm_destroy"
    follow_redirect!
    assert_equal 403, last_response.status
    sign_in_with_rack(@attendee)
    get "#{order_path}/confirm_destroy"
    follow_redirect!
    assert_equal 200, last_response.status
  end
end
