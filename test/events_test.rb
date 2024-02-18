require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class CoreTest < ActiveSupport::TestCase
  include Capybara::DSL

  setup do
    reset!
  end

  teardown do
    save_screenshot unless ENV['CI']
  end

  test 'creating an event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.build_stubbed(:event)
    @ticket_type = FactoryBot.build_stubbed(:ticket_type)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_in 'Event title*', with: @event.name
    execute_script %{$('#event_start_time').val('#{@event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{@event.end_time.to_fs(:db_local)}')}
    fill_in 'Location*', with: @event.location
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: @ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price', with: @ticket_type.price
    fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    assert page.has_content? 'Add to calendar'
  end

  test 'creating an event from /events' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    login_as(@account)
    visit '/events'
    click_link 'Create an event'
    select @organisation.name, from: 'organisation_id'
    assert page.has_content? 'Event title*'
  end

  test 'editing an event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account)
    login_as(@account)
    visit "/events/#{@event.id}/edit"
    fill_in 'Event title*', with: (name = FactoryBot.build_stubbed(:event).name)
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert page.has_content? name
  end

  test 'booking onto a free event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account)
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking!'
  end

  test 'booking onto a paid event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, ticket_price: (ticket_price = 10))
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    click_button "Pay £#{format('%.2f', ticket_price)}"
    fill_in 'cardNumber', with: '4242 4242 4242 4242'
    fill_in 'cardCvc', with: '242'
    fill_in 'cardExpiry', with: '02/42'
    fill_in 'billingName', with: @account.name
    click_button 'Pay'
    # assert page.has_content? 'Thanks for booking!'
  end
end
