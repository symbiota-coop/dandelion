require_relative '../test_config'

# Who a mass email (Pmail) goes to, who may write and send one, and sending it once, now or later
class MessagesPmailSendingTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # Sends through the organisation's own Mailgun account, so mails to followers are always sendable
  def link_mailgun(organisation = @organisation)
    organisation.set(mailgun_api_key: 'key-test', mailgun_domain: 'mg.example.com')
  end

  def follower_of(organisation, **attrs)
    account = FactoryBot.create(:account)
    organisation.organisationships.create!(account: account, **attrs)
    account
  end

  def unsubscribe_from(organisation, account)
    organisation.organisationships.find_by(account: account).set_unsubscribed!(true)
  end

  # Local groups take in the organisation's followers who live in them (Organisationship#associate_with_relevant_local_groups!)
  def join_local_group(local_group, account, **attrs)
    local_group.local_groupships.find_or_create_by!(account: account).tap { |local_groupship| local_groupship.set(**attrs) if attrs.any? }
  end

  def recipients_of(pmail)
    recorded_email { pmail.send_pmail }.recipients.sort
  end

  def edit_path(pmail, scope = "organisation_id=#{@organisation.id}")
    "/pmails/#{pmail.id}/edit?#{scope}"
  end

  def send_pmail_jobs
    Delayed::Job.and(handler: /method_name: :send_pmail$/)
  end

  # Recipients

  test 'a mail to everyone goes to the subscribed followers, never to those who unsubscribed from the organisation or from everything' do
    create_organisation
    link_mailgun
    follower = follower_of(@organisation)
    unsubscribed_from_organisation = follower_of(@organisation)
    unsubscribe_from(@organisation, unsubscribed_from_organisation)
    unsubscribed_from_everything = follower_of(@organisation)
    unsubscribed_from_everything.set(unsubscribed: true)
    follower_of(FactoryBot.create(:organisation))
    FactoryBot.create(:account)
    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')

    email = recorded_email { pmail.send_pmail }

    assert_equal [@account.email, follower.email].sort, email.recipients.sort
    assert_equal pmail.subject, email.subject_line
    # Tagged with the mail, so Mailgun's click webhook can find it
    assert_equal [pmail.id.to_s], email.tags
    # Each gets their own link to unsubscribe from this organisation
    assert_equal follower.organisation_unsubscribe_token_for(@organisation), email.variables[follower.email]['org_unsubscribe_token']
  end

  test 'mails to monthly donors and to everyone else split the subscribed followers between them' do
    create_organisation
    link_mailgun
    donation = { monthly_donation_method: 'GoCardless', monthly_donation_amount: 10, sent_monthly_donation_welcome: true }
    donor = follower_of(@organisation, **donation)
    unsubscribed_donor = follower_of(@organisation, **donation)
    unsubscribe_from(@organisation, unsubscribed_donor)
    follower = follower_of(@organisation)

    donors_pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'monthly_donors')
    others_pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'not_monthly_donors')

    assert_equal [donor.email], recipients_of(donors_pmail)
    assert_equal [@account.email, follower.email].sort, recipients_of(others_pmail)
  end

  test "a mail to an activity goes to its subscribed members, not to those who unsubscribed from it, the organisation or everything, nor to another activity's" do
    create_organisation
    link_mailgun
    activity = FactoryBot.create(:activity, organisation: @organisation)
    member = FactoryBot.create(:account)
    activity.activityships.create!(account: member)
    unsubscribed_from_activity = FactoryBot.create(:account)
    activity.activityships.create!(account: unsubscribed_from_activity, unsubscribed: true)
    unsubscribed_from_organisation = follower_of(@organisation)
    unsubscribe_from(@organisation, unsubscribed_from_organisation)
    activity.activityships.create!(account: unsubscribed_from_organisation)
    unsubscribed_from_everything = FactoryBot.create(:account, unsubscribed: true)
    activity.activityships.create!(account: unsubscribed_from_everything)
    FactoryBot.create(:activity, organisation: @organisation).activityships.create!(account: FactoryBot.create(:account))

    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: "activity:#{activity.id}")

    assert_equal [@account.email, member.email].sort, recipients_of(pmail)
  end

  test "a mail to a local group goes to its subscribed members, not to those who unsubscribed from it or the organisation, nor to another group's" do
    create_organisation
    link_mailgun
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    member = FactoryBot.create(:account)
    join_local_group(local_group, member)
    unsubscribed_from_group = FactoryBot.create(:account)
    join_local_group(local_group, unsubscribed_from_group, unsubscribed: true)
    unsubscribed_from_organisation = follower_of(@organisation)
    unsubscribe_from(@organisation, unsubscribed_from_organisation)
    join_local_group(local_group, unsubscribed_from_organisation)
    join_local_group(FactoryBot.create(:local_group, organisation: @organisation), FactoryBot.create(:account))

    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: "local_group:#{local_group.id}")

    # The organisation's creator lives in the group, so joined it on following the organisation
    assert_equal [@account.email, member.email].sort, recipients_of(pmail)
  end

  test "a mail to an event's attendees goes to its ticket holders, including tickets with only an email, and not to its organisation's followers" do
    create_event
    ticket_type = FactoryBot.create(:ticket_type, event: @event, quantity: 10)
    attendee = FactoryBot.create(:account)
    Ticket.create!(event: @event, account: attendee, ticket_type: ticket_type, price: 0)
    Ticket.create!(event: @event, ticket_type: ticket_type, price: 0, email: 'guest@example.com')
    follower = follower_of(@organisation)
    create_event(as: :other_event)
    other_attendee = FactoryBot.create(:account)
    Ticket.create!(event: @other_event, account: other_attendee, ticket_type: FactoryBot.create(:ticket_type, event: @other_event, quantity: 10), price: 0)

    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: "event:#{@event.id}")

    recipients = recipients_of(pmail)
    assert_includes recipients, attendee.email
    assert_includes recipients, 'guest@example.com'
    assert_not_includes recipients, follower.email
    assert_not_includes recipients, other_attendee.email
  end

  test 'a mail can leave out the attendees of an event and the members of a local group' do
    create_event
    link_mailgun
    ticket_type = FactoryBot.create(:ticket_type, event: @event, quantity: 10)
    attendee = follower_of(@organisation)
    Ticket.create!(event: @event, account: attendee, ticket_type: ticket_type, price: 0)
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    group_member = follower_of(@organisation)
    join_local_group(local_group, group_member)
    follower = follower_of(@organisation)
    local_group.local_groupships.find_by(account: follower)&.destroy

    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone', event: @event, local_group: local_group)

    recipients = recipients_of(pmail)
    assert_includes recipients, follower.email
    assert_not_includes recipients, attendee.email
    assert_not_includes recipients, group_member.email
  end

  # Who may write and send

  test "only the organisation's admins can write, preview or send its mails, not its followers or event managers" do
    covers 'organisations/table-organisation-mailer@64db60'
    create_organisation
    link_mailgun
    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    follower = follower_of(@organisation)
    event_manager = follower_of(@organisation, event_manager: true)

    [follower, event_manager].each do |account|
      sign_in_with_rack(account)
      get "/pmails/new?organisation_id=#{@organisation.id}"
      assert last_response.redirect?
      get "/pmails/#{pmail.id}/preview?organisation_id=#{@organisation.id}"
      assert last_response.redirect?
      assert_no_difference 'Pmail.count' do
        post "/pmails/new?organisation_id=#{@organisation.id}", pmail: { from: pmail.from, subject: 'Mine', body: 'Hi', to_option: 'everyone' }
      end
      email = recorded_email { post edit_path(pmail), pmail: { subject: 'Changed' }, send_test: 1 }
      assert_empty email.recipients
      post edit_path(pmail), pmail: { subject: 'Changed' }, send: 1
      assert last_response.redirect?
    end

    pmail.reload
    assert_not_equal 'Changed', pmail.subject
    assert_nil pmail.requested_send_at
    assert_equal 0, send_pmail_jobs.count
  end

  test "an organisation's admin can't reach another organisation's mails through their own" do
    create_organisation
    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    other_admin = FactoryBot.create(:account)
    other_organisation = FactoryBot.create(:organisation, account: other_admin)
    link_mailgun(other_organisation)
    sign_in_with_rack(other_admin)
    scope = "organisation_id=#{other_organisation.id}"

    get edit_path(pmail, scope)
    assert_equal 404, last_response.status
    get "/pmails/#{pmail.id}/preview?#{scope}"
    assert_equal 404, last_response.status
    post edit_path(pmail, scope), pmail: { subject: 'Changed' }, send: 1
    assert_equal 404, last_response.status
    post "/pmails/#{pmail.id}/destroy?#{scope}"
    assert_equal 404, last_response.status
    get "/pmails/#{@organisation.id}/attachments?#{scope}"
    assert_equal 403, last_response.status

    pmail.reload
    assert_not_equal 'Changed', pmail.subject
    assert_nil pmail.requested_send_at
    assert_equal 0, send_pmail_jobs.count
  end

  test "an activity's admin can mail its members, but not the organisation's followers, another activity's members or the organisation's own mails" do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    other_activity = FactoryBot.create(:activity, organisation: @organisation)
    activity_admin = FactoryBot.create(:account)
    activity.activityships.create!(account: activity_admin).set(admin: true)
    organisation_pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    sign_in_with_rack(activity_admin)
    scope = "activity_id=#{activity.id}"
    fields = { from: "Admin <admin@#{ENV['DOMAIN']}>", body: 'Hi' }

    post "/pmails/new?#{scope}", pmail: fields.merge(subject: 'Members', to_option: "activity:#{activity.id}")
    pmail = Pmail.find_by(subject: 'Members')
    assert_equal @organisation, pmail.organisation
    assert_equal activity, pmail.mailable

    assert_no_difference 'Pmail.count' do
      post "/pmails/new?#{scope}", pmail: fields.merge(subject: 'Everyone', to_option: 'everyone')
      post "/pmails/new?#{scope}", pmail: fields.merge(subject: 'Other activity', to_option: "activity:#{other_activity.id}")
    end
    post edit_path(pmail, scope), pmail: { to_option: 'everyone' }, send: 1
    assert_equal activity, pmail.reload.mailable
    assert_nil pmail.requested_send_at

    get edit_path(organisation_pmail, scope)
    assert_equal 404, last_response.status
    get "/pmails/new?activity_id=#{other_activity.id}"
    assert last_response.redirect?
  end

  test "a local group's admin can mail its members, but not the organisation's followers or the organisation's own mails" do
    create_organisation
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    group_admin = FactoryBot.create(:account)
    join_local_group(local_group, group_admin, admin: true)
    organisation_pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    sign_in_with_rack(group_admin)
    scope = "local_group_id=#{local_group.id}"
    fields = { from: "Admin <admin@#{ENV['DOMAIN']}>", body: 'Hi' }

    post "/pmails/new?#{scope}", pmail: fields.merge(subject: 'Members', to_option: "local_group:#{local_group.id}")
    assert_equal local_group, Pmail.find_by(subject: 'Members').mailable
    assert_no_difference 'Pmail.count' do
      post "/pmails/new?#{scope}", pmail: fields.merge(subject: 'Everyone', to_option: 'everyone')
    end
    get edit_path(organisation_pmail, scope)
    assert_equal 404, last_response.status
  end

  test "an event's organiser can mail its attendees, but not the organisation's followers or another event's attendees" do
    create_event
    create_event(as: :other_event)
    organiser = FactoryBot.create(:account)
    @event.set(organiser_id: organiser.id)
    sign_in_with_rack(organiser)
    scope = "event_id=#{@event.id}"
    fields = { from: "Organiser <organiser@#{ENV['DOMAIN']}>", body: 'Hi' }

    post "/pmails/new?#{scope}", pmail: fields.merge(subject: 'Attendees', to_option: "event:#{@event.id}")
    assert_equal @event, Pmail.find_by(subject: 'Attendees').mailable
    assert_no_difference 'Pmail.count' do
      post "/pmails/new?#{scope}", pmail: fields.merge(subject: 'Everyone', to_option: 'everyone')
      post "/pmails/new?#{scope}", pmail: fields.merge(subject: 'Other event', to_option: "event:#{@other_event.id}")
    end
    get "/pmails/new?event_id=#{@other_event.id}"
    assert last_response.redirect?
  end

  # Sending

  test 'a test goes only to the admin sending it, marked as a test' do
    create_organisation
    link_mailgun
    follower_of(@organisation)
    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    sign_in_with_rack(@account)

    email = recorded_email { post edit_path(pmail), pmail: { subject: 'Hello' }, send_test: 1 }

    assert_equal [@account.email], email.recipients
    assert_match(/\AHello \[test sent /, email.subject_line)
    assert_nil pmail.reload.requested_send_at
    assert_equal 0, send_pmail_jobs.count
  end

  test 'a mail can be scheduled to send later, and rescheduled, only through its own Mailgun account and not to event attendees' do
    create_event
    link_mailgun
    follower = follower_of(@organisation)
    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    sign_in_with_rack(@account)
    tomorrow = 1.day.from_now.change(sec: 0)

    post edit_path(pmail), pmail: { will_send_at: tomorrow.strftime('%Y-%m-%d %H:%M') }, send_later: 1
    assert_equal 1, send_pmail_jobs.count
    assert_equal tomorrow.to_i, send_pmail_jobs.first.run_at.to_i
    assert_nil pmail.reload.requested_send_at

    next_week = 1.week.from_now.change(sec: 0)
    post edit_path(pmail), pmail: { will_send_at: next_week.strftime('%Y-%m-%d %H:%M') }, send_later: 1
    assert_equal 1, send_pmail_jobs.count
    assert_equal next_week.to_i, send_pmail_jobs.first.run_at.to_i

    emails = emails_sent_by_jobs(/method_name: :send_pmail$/)
    assert_equal [@account.email, follower.email].sort, emails.first.recipients.sort
    send_pmail_jobs.destroy_all

    # Without a time, nothing is scheduled
    unscheduled = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    post edit_path(unscheduled), pmail: { subject: 'No time' }, send_later: 1
    assert_equal 0, send_pmail_jobs.count

    # Nor without the organisation's own Mailgun account, nor to an event's attendees
    event_pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: "event:#{@event.id}")
    post edit_path(event_pmail), pmail: { will_send_at: tomorrow.strftime('%Y-%m-%d %H:%M') }, send_later: 1
    assert_equal 0, send_pmail_jobs.count
    @organisation.set(mailgun_api_key: nil)
    post edit_path(unscheduled), pmail: { will_send_at: tomorrow.strftime('%Y-%m-%d %H:%M') }, send_later: 1
    assert_equal 0, send_pmail_jobs.count
  end

  test "a sent mail can't be deleted" do
    create_organisation
    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    pmail.set(sent_at: Time.now)
    sign_in_with_rack(@account)

    post "/pmails/#{pmail.id}/destroy?organisation_id=#{@organisation.id}"

    assert_equal 403, last_response.status
    assert Pmail.find(pmail.id)
  end

  # On the web

  test "an unsent mail can't be viewed on the web, even with its token" do
    create_organisation
    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')

    get "/pmails/#{pmail.token}"
    assert_equal 404, last_response.status

    pmail.set(sent_at: Time.now)
    get "/pmails/#{pmail.token}"
    assert last_response.ok?
    assert_includes last_response.body, pmail.subject
  end

  # A Mailgun click event for pmail at url from a device_type, signed with key
  def mailgun_click_event(pmail, url:, key:, device_type: nil)
    timestamp = Time.now.to_i.to_s
    token = SecureRandom.hex(25)
    {
      'signature' => { 'timestamp' => timestamp, 'token' => token, 'signature' => OpenSSL::HMAC.hexdigest('SHA256', key, "#{timestamp}#{token}") },
      'event-data' => { 'event' => 'clicked', 'tags' => [pmail.id.to_s], 'url' => url, 'client-info' => { 'device-type' => device_type } }
    }.to_json
  end

  test "clicks are counted per link, by device, without recipients' tokens, and only for the organisation's own mails" do
    create_organisation(mailgun_webhook_signing_key: 'organisation-key')
    pmail = FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    webhook = "/o/#{@organisation.slug}/mailgun_webhook"

    post webhook, mailgun_click_event(pmail, url: 'https://example.com/page?a=1&link_token=secret', key: 'organisation-key', device_type: 'mobile'), 'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status
    post webhook, mailgun_click_event(pmail, url: 'https://example.com/page?a=1&sign_in_token=secret', key: 'organisation-key', device_type: 'desktop'), 'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status

    assert_equal 1, pmail.pmail_links.count
    link = pmail.pmail_links.first
    assert_equal 'https://example.com/page?a=1', link.url
    assert_equal 2, link.clicks
    assert_equal 1, link.mobile_clicks
    assert_equal 1, link.desktop_clicks

    # Another organisation's mail, though signed with this organisation's key
    other_pmail = FactoryBot.create(:pmail, organisation: FactoryBot.create(:organisation), to_option: 'everyone')
    post webhook, mailgun_click_event(other_pmail, url: 'https://example.com/page', key: 'organisation-key'), 'CONTENT_TYPE' => 'application/json'
    assert_equal 404, last_response.status
    assert_equal 0, other_pmail.pmail_links.count
  end
end
