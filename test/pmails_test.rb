require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class PmailsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

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
    assert page.has_no_title?('pwned')
  end

  test 'sent pmails are viewable by token but not by id' do
    create_organisation
    pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone')
    pmail.set(sent_at: Time.now)
    assert pmail.token.present?
    visit "/pmails/#{pmail.token}"
    assert page.has_title? pmail.subject
    visit "/pmails/#{pmail.id}"
    assert page.has_no_title?(pmail.subject)
  end

  test 'legacy pmails without a token are still viewable by id' do
    create_organisation
    pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone')
    pmail.set(sent_at: Time.now, token: nil)
    visit "/pmails/#{pmail.id}"
    assert page.has_title? pmail.subject
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
    covers 'organisations/who-becomes-event-admin@459b2f', 'organisations/table-organisation-mailer@64db60'
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
    visit "/e/#{@event.slug}/pmails"

    assert page.has_content? 'Ticket group Backstage'
  end

  test 'ticket type waitlist pmails target waiters for a ticket type or all ticket types' do
    covers 'events/mailer-to-waitlist@62f7ed', 'events/mailer-to-ticket-type-waitlists@c83e93', 'mailer/waitlist-recipients@085f4c'
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
    visit "/e/#{@event.slug}/pmails"

    assert page.has_content? 'Ticket type waitlist Weekend'
    assert page.has_content? 'Ticket type waitlists:'
  end

  test 'event pmail to options include ticket type waitlists when enabled' do
    covers 'events/mailer-to-waitlist@62f7ed', 'events/mailer-to-ticket-type-waitlists@c83e93', 'mailer/waitlist-recipients@085f4c'
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
      context = EmailHelper::TemplateContext.new(name: 'Hi %recipient.firstname% %recipient.token% 50%20', raw: '%recipient.token%')
      html = EmailHelper.render_erb(file.path, context)

      assert_includes html, "<p>Hi %recipient.firstname% %\u200Crecipient.token% 50%20</p>"
      assert_includes html, '<p>%recipient.token%</p>'
    end
  end

  test 'untrusted keeps public recipient variables working and disables every other one' do
    assert_equal '%recipient.firstname% %recipient.id%', EmailHelper.untrusted('%recipient.firstname% %recipient.id%')
    assert_equal "%\u200Crecipient.new_secret%", EmailHelper.untrusted('%recipient.new_secret%')
    assert_equal "%\u200Crecipient.firstname%\u200Crecipient.token%", EmailHelper.untrusted('%recipient.firstname%recipient.token%')
    assert_equal "%\u200Crecipient.unsubscribe_url%", EmailHelper.untrusted('%recipient.unsubscribe_url%')
    assert_equal "%\u200Cunsubscribe_url% %\u200C_x%", EmailHelper.untrusted('%unsubscribe_url% %_x%')
    assert_equal "%\u200Crecipient.token%", EmailHelper.untrusted(EmailHelper.untrusted('%recipient.token%'))
    assert_equal "%%\u200Crecipient.lastname%%", EmailHelper.untrusted('%%recipient.lastname%%')
    assert_equal "%\u200Crecipient.username%\u200Crecipient%recipient.fullname%", EmailHelper.untrusted('%recipient.username%recipient%recipient.fullname%')
    assert_equal 'Hi %recipient.firstname%, 50% off', EmailHelper.untrusted('Hi %recipient.firstname%, 50% off')
    assert_equal "Ada \u200C%\u200C recipient.token\u200C%\u200C", EmailHelper.recipient_value(EmailHelper.recipient_value('Ada % recipient.token%'))
    html = EmailHelper.rich_text('<figure class="image" style="width: 50%;"><img src="https://example.com/a.png"></figure><p style="width:25%">50% off</p>')
    assert_includes html, 'width: 50%;'
    assert_includes html, 'width:25%'
    assert_includes html, '50% off'
  end

  test 'pmail can exclude a cohosted event' do
    create_organisation
    event = FactoryBot.create(:event)
    event.cohostships.create!(organisation: @organisation)
    pmail = FactoryBot.build(:pmail, organisation: @organisation, event: event)

    assert pmail.valid?, pmail.errors.full_messages.to_sentence
  end

  def add_followers(organisation, count)
    Organisationship.collection.insert_many(Array.new(count) do
      { account_id: BSON::ObjectId.new, organisation_id: organisation.id, created_at: Time.now.utc, updated_at: Time.now.utc, unsubscribed: false }
    end)
  end

  test 'the free gift is one email a month for up to 1000 subscribers, beyond which a Mailgun account is needed, and event attendees can always be emailed' do
    covers 'organisations/free-gift-email@d1a3d1', 'mailer/free-gift-limit@fac05c'
    with_env('MAILGUN_FREE_SUBSCRIBER_LIMIT' => '1000') do
      create_event
      # With its creator, 1000
      add_followers(@organisation, 999)
      assert_equal 1000, @organisation.organisationships.count
      pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone')
      assert pmail.sendable?

      # Sent through Dandelion's Mailgun, as a gift
      pmail.send_batch_message
      assert pmail.reload.gift?

      # One a month
      pmail.set(requested_send_at: Time.now, sent_at: Time.now)
      next_pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone')
      refute next_pmail.sendable?
      pmail.set(requested_send_at: 32.days.ago, sent_at: 32.days.ago)
      assert next_pmail.sendable?

      # Up to 1000 subscribers
      add_followers(@organisation, 1)
      refute next_pmail.sendable?

      # Beyond that, a Mailgun account
      @organisation.set(mailgun_api_key: 'key-test', mailgun_domain: 'mg.example.com')
      assert next_pmail.reload.sendable?
      @organisation.set(mailgun_api_key: nil, mailgun_domain: nil)

      # Event attendees, always
      pmail.set(requested_send_at: Time.now, sent_at: Time.now)
      event_pmail = FactoryBot.create(:pmail, organisation: @organisation, mailable: @event, recipient_kind: 'event')
      refute next_pmail.reload.sendable?
      assert event_pmail.sendable?
      event_pmail.send_batch_message
      refute event_pmail.reload.gift?
    end
  end

  test 'followers who unsubscribed count towards the free gift limit' do
    covers 'organisations/free-gift-email@d1a3d1', 'mailer/free-gift-limit@fac05c'
    with_env('MAILGUN_FREE_SUBSCRIBER_LIMIT' => '1000') do
      create_event
      # With its creator, 1000
      add_followers(@organisation, 999)
      pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone')
      assert pmail.sendable?

      Organisationship.collection.insert_one(account_id: BSON::ObjectId.new, organisation_id: @organisation.id, created_at: Time.now.utc,
                                             updated_at: Time.now.utc, unsubscribed: true)
      refute pmail.reload.sendable?
    end
  end

  test "the free gift counts the people mailed, so an activity's imported members beyond the limit need a Mailgun account" do
    covers 'organisations/free-gift-email@d1a3d1', 'mailer/free-gift-limit@fac05c'
    with_env('MAILGUN_FREE_SUBSCRIBER_LIMIT' => '3') do
      create_event
      activity = FactoryBot.create(:activity, organisation: @organisation)
      # With its creator, 3, none of them following the organisation
      activity.import_from_csv_without_delay("name,email\nA,a@#{ENV['DOMAIN']}\nB,b@#{ENV['DOMAIN']}\n", :activityships)
      pmail = FactoryBot.create(:pmail, organisation: @organisation, mailable: activity, recipient_kind: 'activity')
      assert_equal 1, @organisation.organisationships.count
      assert_equal 3, pmail.send_count
      assert pmail.sendable?

      activity.import_from_csv_without_delay("name,email\nC,c@#{ENV['DOMAIN']}\n", :activityships)
      assert_equal 1, @organisation.organisationships.count
      assert_equal 4, pmail.send_count
      refute pmail.sendable?
      assert_nil pmail.send_batch_message
      refute pmail.reload.gift?
    end
  end

  # Mailgun's tag stats for a month with these totals
  def mailgun_tag_stats(delivered:, opened:, clicked:)
    {
      'stats' => [{
        'accepted' => { 'incoming' => 0, 'outgoing' => delivered, 'total' => delivered },
        'delivered' => { 'smtp' => delivered, 'http' => 0, 'optimized' => 0, 'total' => delivered },
        'failed' => {
          'temporary' => { 'espblock' => 0, 'total' => 0 },
          'permanent' => { 'suppress-bounce' => 0, 'suppress-unsubscribe' => 0, 'suppress-complaint' => 0, 'bounce' => 0,
                           'delayed-bounce' => 0, 'webhook' => 0, 'optimized' => 0, 'total' => 0 }
        },
        'stored' => { 'total' => 0 },
        'opened' => { 'total' => opened, 'unique' => opened },
        'clicked' => { 'total' => clicked, 'unique' => clicked },
        'unsubscribed' => { 'total' => 0 },
        'complained' => { 'total' => 0 }
      }]
    }
  end

  # The pmail's edit page, with Mailgun answering its tag stats with stats, and the domains asked for in domains
  def get_pmail_edit_page(pmail, stats:, domains:)
    tags = Object.new
    tags.define_singleton_method(:get_tag_stats) do |domain, *|
      domains << domain
      stats
    end
    Mailgun::Tags.stub(:new, tags) { get "/pmails/#{pmail.id}/edit?organisation_id=#{@organisation.id}" }
    assert last_response.ok?
    last_response.body
  end

  test 'a sent free gift message shows its delivery, open and click rates, and own Mailgun accounts also get a link to Mailgun analytics' do
    covers 'organisations/free-gift-email-analytics@2fc6d9', 'mailer/free-gift-rates@6782fe'
    stats = mailgun_tag_stats(delivered: 200, opened: 50, clicked: 10)
    create_organisation
    sign_in_with_rack(@account)
    pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone')
    pmail.set(gift: true, requested_send_at: Time.now, sent_at: Time.now)

    with_env('MAILGUN_API_KEY' => 'key-dandelion', 'MAILGUN_PMAILS_HOST' => 'mailer.dandelion.test') do
      domains = []
      body = get_pmail_edit_page(pmail, stats: stats, domains: domains)
      # Read from Dandelion's Mailgun, which sent it
      assert_equal ['mailer.dandelion.test'], domains.uniq
      assert_includes body, 'Delivered rate'
      assert_includes body, '100.00%'
      assert_includes body, 'Opened rate'
      assert_includes body, '25.00%'
      assert_includes body, 'Clicked rate'
      assert_includes body, '5.00%'
      refute_includes body, 'View analytics on Mailgun'
    end

    @organisation.set(mailgun_api_key: 'key-test', mailgun_domain: 'mg.example.com')
    pmail.set(gift: false)
    domains = []
    body = get_pmail_edit_page(pmail, stats: stats, domains: domains)
    assert_equal ['mg.example.com'], domains.uniq
    assert_includes body, 'Opened rate'
    assert_includes body, 'View analytics on Mailgun'
    assert_includes body, 'https://app.mailgun.com/mg/reporting/metrics?'
  end
end
