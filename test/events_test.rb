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
    assert page.has_content? 'Drag the slider'
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
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [0])
    login_as(@account)
    visit "/e/#{@event.slug}/edit"
    fill_in 'Event title*', with: (name = FactoryBot.build_stubbed(:event).name)
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert page.has_content? name
  end

  test 'booking onto a free event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [0])
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    click_button 'RSVP'
    assert page.has_content? 'Thanks for booking!'
  end

  test 'booking onto a paid event' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [(ticket_price = 10)], suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types.first.id}]"
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', ticket_price + donation_amount)}"
  end

  test 'booking onto a paid event with a range' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: ['10-100'], suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    execute_script %{$("[name='prices[#{@event.ticket_types.first.id}]']").val(#{selected_price = 50})[0].oninput()}
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'booking onto a paid event with a user-set price' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [nil], suggested_donation: 0)
    login_as(@account)
    visit "/e/#{@event.slug}"
    fill_in "prices[#{@event.ticket_types.first.id}]", with: (selected_price = 50)
    fill_in 'donation_amount', with: (donation_amount = 5)
    assert page.has_button? "Pay £#{format('%.2f', selected_price + donation_amount)}"
  end

  test 'discount codes preserve quantities and prices' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [(price_0 = 10), '10-100', nil], suggested_donation: 0, questions: "q0\n[q1]\nq2")
    @discount_code = FactoryBot.create(:discount_code, codeable: @event, code: (code = 'DISCOUNT10'), percentage_discount: (percentage_discount = 10))
    login_as(@account)
    visit "/e/#{@event.slug}"
    select 1, from: "quantities[#{@event.ticket_types[0].id}]"
    execute_script %{$("[name='prices[#{@event.ticket_types[1].id}]']").val(#{price_1 = 50})[0].oninput()}
    fill_in "prices[#{@event.ticket_types[2].id}]", with: (price_2 = 50)
    execute_script %{$("[name='prices[#{@event.ticket_types[2].id}]']")[0].oninput()}
    fill_in 'donation_amount', with: (donation_amount = 5)
    fill_in 'answers[0]', with: 'a0'
    fill_in 'answers[2]', with: 'a2'
    fill_in 'discount_code', with: code
    click_button 'Apply'
    assert_equal find_field("quantities[#{@event.ticket_types[0].id}]").value, '1'
    assert_equal find_field("prices[#{@event.ticket_types[1].id}]").value, price_1.to_s
    assert_equal find_field("prices[#{@event.ticket_types[2].id}]").value, price_2.to_s
    assert_equal find_field('donation_amount').value, donation_amount.to_s
    assert_equal find_field('answers[0]').value, 'a0'
    assert_equal find_field('answers[2]').value, 'a2'
    assert_equal find_field('discount_code_display', disabled: true).value, code
    assert page.has_button? "Pay £#{format('%.2f', ((price_0 + price_1 + price_2) * (100 - percentage_discount).to_f / 100) + donation_amount)}"
  end
end
