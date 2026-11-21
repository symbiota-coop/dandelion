require_relative '../test_config'

# Locked events, like those submitted for an organisation to review: only their admins can open them
class EventLockedTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  test "a locked event's page sends anyone but its admins to the organisation's events" do
    create_event(prices: [0], locked: true, name: 'Locked gathering')
    ticketholder = FactoryBot.create(:account)
    @event.tickets.create!(account: ticketholder, ticket_type: @event.ticket_types.first, payment_completed: true)

    [ticketholder, FactoryBot.create(:account)].each do |account|
      sign_in_with_rack(account)
      get "/e/#{@event.slug}"
      assert_redirected_to "/o/#{@organisation.slug}/events"
    end
    clear_cookies
    get "/e/#{@event.slug}"
    assert_redirected_to "/o/#{@organisation.slug}/events"

    [@organisation.account, create_facilitator(@event)].each do |admin|
      sign_in_with_rack(admin)
      get "/e/#{@event.slug}"
      assert last_response.ok?
      assert_includes last_response.body, 'Locked gathering'
    end
  end

  # People who aren't the locked event's admins: someone with a ticket, someone else, and someone signed out
  def locked_event_outsiders
    ticketholder = FactoryBot.create(:account)
    @event.tickets.create!(account: ticketholder, ticket_type: @event.ticket_types.first, payment_completed: true)
    [ticketholder, FactoryBot.create(:account), nil]
  end

  test "a locked event's sessions' calendar files are for its admins only, as its page is" do
    covers_route 'GET /event_sessions/:id'
    create_event(prices: [0], locked: true, name: 'Locked gathering')
    event_session = @event.event_sessions.create!(start_time: @event.start_time + 1.hour, end_time: @event.start_time + 2.hours)

    locked_event_outsiders.each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get "/event_sessions/#{event_session.id}.ics"
      assert_redirected_to "/o/#{@organisation.slug}/events"
      refute_includes last_response.body, 'Locked gathering'
    end

    [@organisation.account, create_facilitator(@event)].each do |admin|
      sign_in_with_rack(admin)
      get "/event_sessions/#{event_session.id}.ics"
      assert last_response.ok?
      assert_includes last_response.body, 'SUMMARY:Locked gathering'
    end
  end

  test "a locked event's waitlists take no one but its admins, as its page doesn't show them to anyone else" do
    covers_route 'POST /e/:slug/waitship/new', 'POST /e/:slug/ticket_type_waitships'
    create_event(prices: [10], locked: true)
    outsiders = locked_event_outsiders
    @event.ticket_types.first.set(quantity: 0)
    @event.refresh_sold_out_cache_and_notify_waitlist
    create_event(prices: [10], locked: true, allow_ticket_type_waitlists: true, suggested_donation: 0, as: :by_ticket_type)
    ticket_type = @by_ticket_type.ticket_types.first
    ticket_type.set(quantity: 0)
    @by_ticket_type.refresh_sold_out_cache_and_notify_waitlist
    join = lambda do
      post "/e/#{@event.slug}/waitship/new", waitship: { name: 'Wait Lister', email: 'waiter@example.com' }
      event_waitlist = last_response
      post "/e/#{@by_ticket_type.slug}/ticket_type_waitships", { ticket_type_id: ticket_type.id.to_s, name: 'Wait Lister', email: 'waiter@example.com' },
           'HTTP_ACCEPT' => 'application/json'
      [event_waitlist, last_response]
    end

    outsiders.each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      join.call.each do |response|
        assert response.redirect?, "Expected a redirect, got #{response.status}"
        assert_equal "/o/#{@organisation.slug}/events", URI(response.location).path
      end
    end
    assert_equal 0, @event.waitships.count
    assert_equal 0, ticket_type.ticket_type_waitships.count
    assert_nil Account.find_by(email: 'waiter@example.com')

    sign_in_with_rack(@organisation.account)
    event_waitlist, ticket_type_waitlist = join.call
    assert_equal "/e/#{@event.slug}", URI(event_waitlist.location).path
    assert_equal 200, ticket_type_waitlist.status, ticket_type_waitlist.body
    assert_equal 1, @event.waitships.count
    assert_equal 1, ticket_type.ticket_type_waitships.count
  end

  test "someone who isn't an admin of a locked event is shown the organisation's events instead" do
    create_event(prices: [0], locked: true, name: 'Locked gathering')
    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}"
    assert page.has_current_path?("/o/#{@organisation.slug}/events")
    assert page.has_content?("You don't have access to that page")
    assert page.has_no_content?('Locked gathering')

    sign_in(@organisation.account)
    visit "/e/#{@event.slug}"
    assert page.has_current_path?("/e/#{@event.slug}")
    assert page.has_content?('Locked gathering')
  end
end
