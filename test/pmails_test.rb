require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class PmailsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating a pmail' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @pmail = FactoryBot.build_stubbed(:pmail)
    login_as(@account)
    visit "/o/#{@organisation.slug}/pmails"
    click_link 'New message'
    fill_in 'Subject', with: @pmail.subject
    execute_script %{$('#pmail_to_option').val('everyone')}
    click_button 'Save'
    assert page.has_content? 'The mail was saved'
  end

  test 'editing a pmail' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @pmail = FactoryBot.create(:pmail, organisation: @organisation, everyone: true)
    login_as(@account)
    visit "/o/#{@organisation.slug}/pmails"
    click_link 'Edit'
    fill_in 'Subject', with: (subject = FactoryBot.build_stubbed(:pmail).subject)
    click_button 'Save'
    assert page.has_content? 'The mail was saved'
    visit "/pmails/#{@pmail.id}/preview?organisation_id=#{@organisation.id}"
    assert page.has_title? subject
  end

  test 'ticket group pmail does not fall back to event recipients when group is deleted' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account)
    ticket_group = event.ticket_groups.create!(name: 'Backstage', capacity: 10)
    ticket_type = FactoryBot.create(:ticket_type, event: event, ticket_group: ticket_group, quantity: 10)
    other_ticket_type = FactoryBot.create(:ticket_type, event: event, quantity: 10)
    attendee = FactoryBot.create(:account)
    other_attendee = FactoryBot.create(:account)
    Ticket.create!(event: event, account: attendee, ticket_type: ticket_type, price: 0)
    Ticket.create!(event: event, account: other_attendee, ticket_type: other_ticket_type, price: 0)
    Ticket.create!(event: event, ticket_type: ticket_type, price: 0, email: 'guest@example.com')
    pmail = FactoryBot.create(:pmail, organisation: organisation, account: account, to_option: "ticket_group:#{ticket_group.id}")
    ticket_group_id = ticket_group.id

    assert_equal [attendee.id], pmail.to.pluck(:id)
    assert_equal 2, pmail.send_count

    ticket_group.destroy
    pmail.reload

    assert_equal "ticket_group:#{ticket_group_id}", pmail.to_selected
    assert_empty pmail.to.pluck(:id)
    assert_empty pmail.event_emails
    assert_equal 0, pmail.send_count

    pmail.to_option = "ticket_group:#{ticket_group_id}"
    pmail_count = Pmail.count
    assert_nil pmail.duplicate!(account)
    assert_equal pmail_count, Pmail.count
    assert_includes pmail.errors.full_messages, 'This mail cannot be duplicated because its ticket group no longer exists.'

    login_as(account)
    visit "/pmails/#{pmail.id}/edit?event_id=#{event.id}"
    pmail_count = Pmail.count
    click_button 'Duplicate'

    assert page.has_content? 'This mail cannot be duplicated because its ticket group no longer exists.'
    assert_equal pmail_count, Pmail.count

    visit "/pmails/#{pmail.id}/edit?event_id=#{event.id}"
    fill_in 'Subject', with: 'Still a deleted ticket group'
    click_button 'Save'

    assert page.has_content? 'The mail was saved'
    pmail.reload
    assert_equal 'Still a deleted ticket group', pmail.subject
    assert_equal "ticket_group:#{ticket_group_id}", pmail.to_selected
    assert_empty pmail.to.pluck(:id)
  end

  test 'ticket group pmail is labelled in the pmail list' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account)
    ticket_group = event.ticket_groups.create!(name: 'Backstage', capacity: 10)
    FactoryBot.create(:pmail, organisation: organisation, account: account, to_option: "ticket_group:#{ticket_group.id}")

    login_as(account)
    visit "/events/#{event.id}/pmails"

    assert page.has_content? 'Ticket group Backstage'
  end
end
