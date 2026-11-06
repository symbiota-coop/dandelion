require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EvergreenEventsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def create_evergreen_event(**attrs)
    create_event(:evergreen, prices: [0], **attrs)
  end

  def create_evergreen_order
    @attendee = FactoryBot.create(:account)
    create_evergreen_event
    @order = @event.orders.create!(account: @attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'Manual test order')
  end

  # Stands in for Mailgun::BatchMessage, keeping what an email would say and attach
  class RecordedEmail
    attr_reader :html, :attachment_names

    def initialize
      @attachment_names = []
    end

    def add_attachment(_file, filename)
      @attachment_names << filename
    end

    def body_html(html)
      @html = html
    end

    def subject(*); end
    def from(*); end
    def reply_to(*); end
    def add_recipient(*); end
    def finalize; end
  end

  # The confirmation email of an order of a ticket to the event
  def confirmation_email(event)
    order = event.orders.create!(account: @account, currency: event.currency, value: 0, payment_completed: true)
    event.tickets.create!(account: @account, order: order, ticket_type: event.ticket_types.first, payment_completed: true)
    email = RecordedEmail.new
    Mailgun::BatchMessage.stub(:new, email) { order.send_tickets_without_delay }
    email
  end

  test 'creating an evergreen event without dates' do
    create_organisation
    ticket_type = FactoryBot.build_stubbed(:ticket_type)
    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_in 'Event title*', with: 'On-demand Ruby Course'
    click_link 'Mark as evergreen/on-demand, with no dates or location'
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    assert page.has_current_path?(%r{\A/e/[^/?]+\?created=1\z})
    assert page.has_no_content?('Add to calendar')
  end

  test 'evergreen event appears in future scope' do
    create_evergreen_event
    assert_includes Event.future_current_evergreen.pluck(:id), @event.id
    refute_includes Event.past.pluck(:id), @event.id
    refute_includes Event.finished.pluck(:id), @event.id
  end

  test 'evergreen event instance methods return correct values' do
    event = Event.new(evergreen: true, name: 'Test', currency: 'GBP')
    assert event.future?
    refute event.past?
    refute event.started?
    refute event.finished?
    assert_nil event.when_details('UTC')
    assert_nil event.concise_when_details('UTC')
    assert_nil event.ical
  end

  test 'non-evergreen event still requires start_time end_time location' do
    event = Event.new(name: 'Missing Dates', currency: 'GBP')
    refute event.valid?
    assert event.errors[:start_time].any?
    assert event.errors[:end_time].any?
    assert event.errors[:location].any?
  end

  test 'evergreen event prevents duplicate names within same organisation' do
    create_evergreen_event(name: 'My Course')
    duplicate = Event.new(
      name: 'My Course',
      currency: 'GBP',
      organisation: @organisation,
      account: @account,
      last_saved_by: @account,
      evergreen: true
    )
    refute duplicate.valid?
    assert duplicate.errors[:name].any?
  end

  test 'duplicating an evergreen event preserves the flag' do
    create_evergreen_event
    duplicate = @event.duplicate!(@account)
    assert duplicate.evergreen?
    assert_nil duplicate.start_time
    assert_nil duplicate.end_time
  end

  test 'booking onto a free evergreen event' do
    create_evergreen_event
    sign_in(@account)
    visit "/e/#{@event.slug}"
    assert page.has_content? 'Online'
    assert page.has_content? 'Register for free'
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking'
  end

  test 'evergreen event reminder_due_within returns false' do
    covers 'events/evergreen-no-reminders-or-feedback@b0f8f7'
    event = Event.new(evergreen: true, name: 'Test', currency: 'GBP', reminder_hours_before: 24)
    refute event.reminder_due_within?(1.hour)
  end

  test 'evergreen event feedback_due_within returns false' do
    covers 'events/evergreen-no-reminders-or-feedback@b0f8f7'
    event = Event.new(
      evergreen: true,
      name: 'Test',
      currency: 'GBP',
      feedback_questions: 'Q?',
      end_time: 1.day.ago,
      feedback_hours_after: 1
    )
    refute event.feedback_due_within?(1.hour)
  end

  test 'evergreen event json endpoint returns nil dates' do
    create_evergreen_event

    get "/e/#{@event.slug}.json"

    assert_equal 200, last_response.status
    json = JSON.parse(last_response.body)
    assert_equal @event.name, json['name']
    assert_nil json['start_time']
    assert_nil json['end_time']
  end

  test 'organisation orders page renders evergreen orders' do
    create_evergreen_order

    sign_in(@account)
    visit "/o/#{@organisation.slug}/orders"

    assert page.has_content? @event.name
    assert page.has_content? @attendee.name
  end

  test "organisation orders page shows each event's progress with the page, rather than a request for each order" do
    create_evergreen_order
    @event.tickets.create!(account: @attendee, order: @order, ticket_type: @event.ticket_types.first, payment_completed: true)

    sign_in_with_rack(@account)
    get "/o/#{@organisation.slug}/orders"
    assert_equal 200, last_response.status
    assert_match %r{data-pagelet-url="/e/#{@event.slug}/progress\?full_width=true" class="my-1">\s*<a href="/e/#{@event.slug}/tickets">}, last_response.body
  end

  test 'evergreen event calendar endpoints return not found' do
    create_evergreen_order

    get "/e/#{@event.slug}.ics"
    assert_equal 404, last_response.status
    get "/orders/#{@order.public_id}.ics"
    assert_equal 404, last_response.status
  end

  test 'converting a scheduled event to evergreen wipes start time, end time, and location' do
    create_event(location: 'London', prices: [0])
    assert @event.start_time
    assert @event.end_time
    @event.update!(evergreen: true)
    @event.reload
    assert_nil @event.start_time
    assert_nil @event.end_time
    assert_equal 'Online', @event.location
  end

  test 'evergreen events show first in listings and carousels, as On-demand instead of under a date' do
    covers 'events/evergreen-first-without-date@6b61cc'
    create_event(as: :event1, name: 'Dated listing event', prices: [0])
    create_evergreen_event(name: 'On-demand listing event')
    [@event1, @event].each { |event| event.set(has_image: true, featured: true) }

    get "/o/#{@organisation.slug}/events", display: 'grid'
    grid = last_response.body.split('id="events-grid"', 2).last
    badges = grid.scan(%r{<span[^>]*badge-overlay[^>]*>(.*?)</span>}m).map { |(badge)| badge.squish }
    assert_equal 2, badges.length
    assert_equal 'On-demand', badges.first
    assert_equal @event1.start_time.to_date.to_fs(:no_year), badges.last.sub('Starts ', '')

    get "/o/#{@organisation.slug}/events", {}, { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    assert_operator last_response.body.index('On-demand listing event'), :<, last_response.body.index('Dated listing event')

    get "/o/#{@organisation.slug}/carousels/featured"
    badges = last_response.body.scan(%r{<span[^>]*badge-overlay[^>]*>(.*?)</span>}m).map { |(badge)| badge.squish }
    assert_equal 2, badges.length
    assert_equal 'On-demand', badges.first
  end

  test 'evergreen events get no PDF tickets, and the confirmation refers to a link' do
    covers 'events/evergreen-no-pdf-link@d1c7ce'
    create_organisation(show_details_table_in_ticket_emails: true)
    create_event(as: :dated_event, prices: [0])
    email = confirmation_email(@dated_event)
    assert(email.attachment_names.any? { |name| name.end_with?('.pdf') })
    assert_includes email.html, 'Your ticket to'
    assert_includes email.html, 'attached'

    create_evergreen_event
    assert @event.no_tickets_pdf?
    email = confirmation_email(@event)
    assert_empty email.attachment_names
    assert_includes email.html, 'Your link to'
    refute_includes email.html, 'ticket to'
    refute_includes email.html, 'attached'
  end
end
