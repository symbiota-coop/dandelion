require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class CoreTest < ActiveSupport::TestCase
  include Capybara::DSL

  setup do
    reset!
  end

  teardown do
    save_screenshot unless ENV['CI']
  end

  test 'listing an event from the homepage' do
    @account = FactoryBot.build_stubbed(:account)
    @organisation = FactoryBot.build_stubbed(:organisation)
    @event = FactoryBot.build_stubbed(:event)
    @ticket_type = FactoryBot.build_stubbed(:ticket_type)
    visit '/'
    click_link 'List an event'
    fill_in 'Name', with: @account.name
    fill_in 'Email', with: @account.email
    fill_in 'Location', with: @account.location
    click_button 'Sign up'
    fill_in 'Organisation name', with: @organisation.name
    fill_in 'Slug', with: @organisation.slug
    click_button 'Save and continue'
    click_button 'Update organisation'
    fill_in 'Event title*', with: @event.name
    execute_script %{$('#event_start_time').val('#{@event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{@event.end_time.to_fs(:db_local)}')}
    fill_in 'Location*', with: @event.location
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: @ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: @ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    assert page.has_content? 'Add to calendar'
  end
end
