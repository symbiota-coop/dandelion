require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'rack/test'

class EvergreenEventsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def app
    Padrino.application
  end

  test 'creating an evergreen event without dates' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @ticket_type = FactoryBot.build_stubbed(:ticket_type)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_in 'Event title*', with: 'On-demand Ruby Course'
    click_link 'Mark as evergreen/on-demand, with no dates or location'
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: @ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: @ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    refute page.has_content? 'Add to calendar'
  end

  test 'evergreen event appears in future scope' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: true, start_time: nil, end_time: nil, location: nil, prices: [0])
    assert_includes Event.future.pluck(:id), @event.id
    assert_includes Event.future_and_current.pluck(:id), @event.id
    refute_includes Event.past.pluck(:id), @event.id
    refute_includes Event.finished.pluck(:id), @event.id
  end

  test 'evergreen event instance methods return correct values' do
    @event = Event.new(evergreen: true, name: 'Test', currency: 'GBP')
    assert @event.future?
    refute @event.past?
    refute @event.started?
    refute @event.finished?
    assert_nil @event.when_details('UTC')
    assert_nil @event.concise_when_details('UTC')
    assert_nil @event.ical
  end

  test 'evergreen event defaults location to Online' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: true, start_time: nil, end_time: nil, location: nil, prices: [0])
    assert_equal 'Online', @event.location
    assert_nil @event.reminder_hours_before
  end

  test 'evergreen event validates without start_time end_time location' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = Event.new(
      name: 'Evergreen Test',
      currency: 'GBP',
      organisation: @organisation,
      account: @account,
      last_saved_by: @account,
      evergreen: true
    )
    assert @event.valid?, "Expected event to be valid, got errors: #{@event.errors.full_messages.join(', ')}"
  end

  test 'non-evergreen event still requires start_time end_time location' do
    @event = Event.new(name: 'Missing Dates', currency: 'GBP')
    refute @event.valid?
    assert @event.errors[:start_time].any?
    assert @event.errors[:end_time].any?
    assert @event.errors[:location].any?
  end

  test 'evergreen event prevents duplicate names within same organisation' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                              evergreen: true, start_time: nil, end_time: nil, location: nil, name: 'My Course', prices: [0])
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
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: true, start_time: nil, end_time: nil, location: nil, prices: [0])
    duplicate = @event.duplicate!(@account)
    assert duplicate.evergreen?
    assert_nil duplicate.start_time
    assert_nil duplicate.end_time
  end

  test 'booking onto a free evergreen event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: true, start_time: nil, end_time: nil, location: nil, prices: [0])
    login_as(@account)
    visit "/e/#{@event.slug}"
    assert page.has_content? 'Online'
    assert page.has_content? 'Register for free'
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking!'
  end

  test 'evergreen event appears on events listing page' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: true, start_time: nil, end_time: nil, location: nil, prices: [0])
    login_as(@account)
    visit '/events'
    assert page.has_content? @event.name
    assert page.has_content? 'Online'
  end

  test 'evergreen event reminder_due_within returns false' do
    @event = Event.new(evergreen: true, name: 'Test', currency: 'GBP', reminder_hours_before: 24)
    refute @event.reminder_due_within?(1.hour)
  end

  test 'evergreen event json endpoint returns nil dates' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: true, start_time: nil, end_time: nil, location: nil, prices: [0])

    get "/e/#{@event.slug}.json"

    assert_equal 200, last_response.status
    json = JSON.parse(last_response.body)
    assert_equal @event.name, json['name']
    assert_nil json['start_date']
    assert_nil json['end_date']
  end

  test 'organisation orders page renders evergreen orders' do
    @account = FactoryBot.create(:account)
    @attendee = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: true, start_time: nil, end_time: nil, location: nil, prices: [0])
    @event.orders.create!(account: @attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'Manual test order')

    login_as(@account)
    visit "/o/#{@organisation.slug}/orders"

    assert page.has_content? @event.name
    assert page.has_content? @attendee.name
  end

  test 'evergreen event calendar endpoints return not found' do
    @account = FactoryBot.create(:account)
    @attendee = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: true, start_time: nil, end_time: nil, location: nil, prices: [0])
    @order = @event.orders.create!(account: @attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'Manual test order')

    get "/e/#{@event.slug}.ics"
    assert_equal 404, last_response.status
    get "/orders/#{@order.id}.ics"
    assert_equal 404, last_response.status
  end

  test 'converting a scheduled event to evergreen wipes start time, end time, and location' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account,
                                       evergreen: false, location: 'London', prices: [0])
    assert @event.start_time
    assert @event.end_time
    @event.update!(evergreen: true)
    @event.reload
    assert_nil @event.start_time
    assert_nil @event.end_time
    assert_equal 'Online', @event.location
  end
end
