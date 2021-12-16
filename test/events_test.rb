require File.expand_path(File.dirname(__FILE__) + '/test_config.rb')

class CoreTest < ActiveSupport::TestCase
  include Capybara::DSL

  setup do
    Capybara.reset_sessions!
    Dir[Padrino.root('models', '*')].each { |f| f.split('/').last.split('.').first.camelize.constantize.delete_all }
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
    execute_script %{$('#event_start_time').val('#{@event.start_time.to_s(:db)}')}
    execute_script %{$('#event_end_time').val('#{@event.end_time.to_s(:db)}')}
    fill_in 'Location*', with: @event.location
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: @ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price', with: @ticket_type.price
    fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    click_button 'Create event'
    assert page.has_content? 'Add to calendar'
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

  test 'RSVPing to an event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account)
    login_as(@account)
    visit "/events/#{@event.id}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking!'
  end
end
