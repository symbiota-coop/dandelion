require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DandelionTest < ActiveSupport::TestCase
  include Capybara::DSL

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
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: @ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    assert page.has_content? 'Add to calendar'
  end

  test 'creating an event with a range' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.build_stubbed(:event)
    @ticket_type = FactoryBot.build_stubbed(:ticket_type, price_or_range: '10-100')
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
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: @ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    click_link 'Everything else'
    click_button 'Create event'
    assert page.has_content? 'Select a price first'
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
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, price_or_range: (ticket_price = 10), suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', ticket_price + donation_amount)}"
  end

  test 'booking onto a paid event with a range' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, price_or_range: '10-100', suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    execute_script %{$("[name='prices[#{@event.ticket_types.first.id}]']").val(#{selected_price = 50})[0].oninput()}
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'booking onto a paid event with a user-set price' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, price_or_range: nil, suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    fill_in "prices[#{@event.ticket_types.first.id}]", with: (selected_price = 50)
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'booking onto a paid event with booking questions and a discount code' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, price_or_range: (ticket_price = 10), suggested_donation: 0, questions: "q0\n[q1]\nq2")
    @discount_code = FactoryBot.create(:discount_code, codeable: @event, code: (code = 'DISCOUNT10'), percentage_discount: (percentage_discount = 10))
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    # fill_in 'donation_amount', with: (donation_amount = 5) # donations aren't passed across discount codes yet
    fill_in 'answers[0]', with: 'a0'
    fill_in 'answers[2]', with: 'a2'
    fill_in 'discount_code', with: code
    click_button 'Apply'
    assert_equal 'a0', find_field('answers[0]').value
    assert_equal 'a2', find_field('answers[2]').value
    assert page.has_button? "Pay £#{format('%.2f', ticket_price * (100 - percentage_discount).to_f / 100)}"
  end
end
