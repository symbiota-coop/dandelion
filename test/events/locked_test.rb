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
