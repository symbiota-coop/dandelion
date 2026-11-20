require_relative '../test_config'

# Searching people by email: only those who can see their emails can, so an email, or fragments of one, can't find
# whose it is
class AccountsEmailSearchTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  EMAIL = 'robin.attendee@gmail.com'.freeze
  EMAIL_SEARCHES = [EMAIL, '@gmail', 'n.attendee@gm'].freeze

  def email_searched_attendee
    @email_searched_attendee ||= FactoryBot.create(:account, name: 'Robin Attendee', email: EMAIL, has_signed_in: true)
  end

  # An event of an organisation @account admins, which attendee has an order and ticket for, and a facilitator, who
  # can't see attendees' emails as the event doesn't let all event admins see them
  def event_with_attendee
    create_event(prices: [0], show_emails: false)
    order = @event.orders.create!(account: email_searched_attendee, currency: @event.currency, value: 0, payment_completed: true)
    @event.tickets.create!(account: email_searched_attendee, order: order, ticket_type: @event.ticket_types.first, email: EMAIL, payment_completed: true)
    @facilitator = create_facilitator(@event)
    assert Event.email_viewer?(@event, @account)
    refute Event.email_viewer?(@event, @facilitator)
  end

  def search_results(path, query)
    visit "#{path}?q=#{CGI.escape(query)}"
    assert page.has_field?('q', with: query)
  end

  test 'signed out, accounts.json finds people by name but not by email' do
    covers_route 'GET /accounts'
    email_searched_attendee

    get '/accounts.json', q: 'Robin Att'
    results = JSON.parse(last_response.body)['results'].map { |result| result['text'] }
    assert_equal ["Robin Attendee (#{email_searched_attendee.username})"], results

    EMAIL_SEARCHES.each do |query|
      get '/accounts.json', q: query
      assert last_response.ok?
      assert_empty JSON.parse(last_response.body)['results'], "#{query} found the account"
    end
  end

  test "event admins who can't see emails can't search attendees by email, and those who can, can" do
    event_with_attendee
    paths = ["/e/#{@event.slug}/orders", "/e/#{@event.slug}/tickets", "/e/#{@event.slug}/check_in_list"]

    sign_in(@facilitator)
    paths.each do |path|
      search_results(path, 'Robin Att')
      assert page.has_content?('Robin Attendee'), "#{path} didn't find the attendee by name"
      EMAIL_SEARCHES.each do |query|
        search_results(path, query)
        assert page.has_no_content?('Robin Attendee'), "#{path} found the attendee by #{query}"
      end
    end

    sign_in(@account)
    paths.each do |path|
      EMAIL_SEARCHES.each do |query|
        search_results(path, query)
        assert page.has_content?('Robin Attendee'), "#{path} didn't find the attendee by #{query} for an email viewer"
      end
    end
  end
end
