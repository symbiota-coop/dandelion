require_relative '../test_config'

# Every email the app can send renders: each template in app/views/emails, and each Mailer.deliver that gives its body
# as content:, html: or text:, sent by the code that sends it. Emails are rendered in background jobs, where a broken
# template fails quietly, so a new template, or a new Mailer.deliver without one, needs a case here
class MessagesEmailTemplatesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  TEMPLATES_DIR = Padrino.root('app/views/emails')

  # Templates no case sends, and why
  NOT_SENT = {
    '_design_preview' => 'the design guide shows it as a sample (design.erb); no code sends it',
    'feedback_summary' => 'no code sends it; only GET /u/:username/feedback_summary_email_preview shows it, rendered below'
  }.freeze

  # The cases: { name => [the templates it renders, the file of the Mailer.deliver or send_to_founder it covers when
  # that gives no template, whether it needs an unsubscribe link, its block] }
  def self.cases
    @cases ||= {}
  end

  def self.email(name, renders: [], source: nil, unsubscribe: false, &block)
    cases[name] = { renders: renders.map(&:to_s), source: source, unsubscribe: unsubscribe }
    test("#{name} email renders") { check_case(name, &block) }
  end

  # Records the emails the block sends, and the templates rendered as it does
  def sent(&)
    render = EmailHelper.method(:render)
    spy = lambda do |template_name, **locals|
      @rendered << template_name.to_s
      render.call(template_name, **locals)
    end
    @sent_emails += EmailHelper.stub(:render, spy) { recorded_emails(&) }
  end

  def check_case(name, &block)
    @rendered = []
    @sent_emails = []
    instance_exec(&block)
    kase = self.class.cases[name]
    emails = @sent_emails.select { |email| email.recipients.any? }
    assert emails.any?, "#{name}: no email sent"
    missing = kase[:renders] - @rendered
    assert_empty missing, "#{name}: didn't render #{missing.join(', ')}"
    emails.each { |email| assert_email_built(email, name, unsubscribe: kase[:unsubscribe]) }
  end

  PLACEHOLDERS = [
    /translation missing/i, /#\{/, /\{\{/, /\}\}/, /<%/, /%>/, /\bnil\b/, /#<[A-Z]\w*/, /\bundefined method\b/i,
    /\[(?:#{(EmailFields::MAGIC_TAGS + %w[event_link feedback_url sign_in_details gathering_name]).join('|')})\]/
  ].freeze

  def assert_email_built(email, name, unsubscribe:)
    assert email.subject_line.present?, "#{name}: no subject"
    assert email.html.present? || email.text.present?, "#{name}: no body"
    PLACEHOLDERS.each { |pattern| refute_match pattern, email.subject_line, "#{name}: subject #{email.subject_line.inspect}" }
    email.recipients.each { |recipient| assert_match(/\A[^@\s]+@[^@\s]+\z/, recipient, "#{name}: recipient #{recipient.inspect}") }

    if email.html
      document = Nokogiri::HTML(email.html)
      document.css('style, head').each(&:remove)
      body_text = document.text.squish
      assert body_text.present?, "#{name}: empty HTML body"
      PLACEHOLDERS.each { |pattern| refute_match pattern, body_text, "#{name}: HTML body has #{pattern.inspect}: #{body_text.truncate(500)}" }
      # A tag that shows as text was escaped twice
      refute_match(%r{</?(?:p|a|div|br|strong|em|img)\b[^>]*>}i, body_text, "#{name}: escaped HTML in the body")
      assert_links_absolute(document, name)
      if unsubscribe
        assert document.css('a[href]').any? { |a| a['href'].match?(%r{/unsubscribe|/accounts/subscriptions}) }, "#{name}: no unsubscribe link"
      end
    end

    if email.text
      PLACEHOLDERS.each { |pattern| refute_match pattern, email.text, "#{name}: text body has #{pattern.inspect}" }
    end

    assert_recipient_variables_given(email, name)
  end

  # Every link and image is a full URL: on our site (BASE_URI, https:// in production), https://, mailto: or a
  # recipient variable that holds one
  def assert_links_absolute(document, name)
    base = ENV.fetch('BASE_URI')
    document.css('a[href], img[src]').each do |node|
      url = node['href'] || node['src']
      assert url.start_with?("#{base}/", 'https://', 'mailto:', '%recipient.') || url == base, "#{name}: link #{url.inspect} isn't absolute"
      next unless url.start_with?(base)

      refute_includes url.delete_prefix(base).split('?').first.to_s, '//', "#{name}: link #{url.inspect} is missing part of its path"
    end
  end

  # Mailgun fills %recipient.x% from each recipient's variables, so every one the email uses must be given to each
  # recipient
  def assert_recipient_variables_given(email, name)
    used = [email.subject_line, email.html, email.text].compact.flat_map { |part| part.scan(/%recipient\.(\w+)%/).flatten }.uniq
    email.recipients.each do |recipient|
      variables = email.variables[recipient] || {}
      missing = used.reject { |variable| variables[variable].present? }
      assert_empty missing, "#{name}: #{recipient} isn't given %recipient.#{missing.join('%, %recipient.')}%"
    end
  end

  # Records

  def admin
    @admin ||= FactoryBot.create(:account, name: 'Ada Admin', admin: true)
  end

  def attendee
    @attendee ||= FactoryBot.create(:account, name: 'Maria Sabina')
  end

  def event_with_admin(**attrs)
    admin
    create_event(prices: [0, 10], **attrs)
  end

  # With every optional part of the ticket email shown
  def ticket_email_organisation
    create_organisation(show_details_table_in_ticket_emails: true, show_sign_in_link_in_ticket_emails: true,
                        show_ticketholder_link_in_ticket_emails: true, affiliate_credit_percentage: 10,
                        extra_info_for_ticket_email: '<p>From the organisation</p>')
  end

  def free_order(account = attendee, answers: nil)
    order = @event.orders.create!(account: account, currency: @event.currency, value: 0, payment_completed: true,
                                  original_description: '1 × Free ticket', answers: answers)
    order.tickets.create!(event: @event, account: account, ticket_type: @event.ticket_types.find_by(price: 0), price: 0, payment_completed: true)
    order
  end

  def paid_order(account = attendee)
    order = @event.orders.create!(account: account, currency: @event.currency, value: 10, payment_completed: true,
                                  payment_intent: "pi_#{SecureRandom.hex(8)}", original_description: '1 × Paid ticket')
    order.tickets.create!(event: @event, account: account, ticket_type: @event.ticket_types.find_by(price: 10), price: 10,
                          payment_completed: true, payment_intent: order.payment_intent)
    order
  end

  def feedback(**attrs)
    event_with_admin
    @event.event_feedbacks.create!(account: attendee, rating: 4, answers: [['How was it?', "Lovely\nevening"]], **attrs)
  end

  def gathering_member
    create_gathering
    create_member(name: 'Gita Member')
  end

  def organisationship_with_donation
    create_organisation
    @organisation.organisationships.create!(account: attendee, monthly_donation_method: 'Patreon', monthly_donation_amount: 5,
                                            monthly_donation_currency: 'GBP', monthly_donation_start_date: Date.today)
  end

  # Accounts

  email 'confirm_email', renders: %i[confirm_email] do
    sent { FactoryBot.create(:account) }
  end

  email 'sign_in_code', renders: %i[sign_in_code] do
    sent { attendee.send_sign_in_code }
  end

  email 'activation_notification', renders: %i[activation_notification] do
    sent { attendee.send_activation_notification }
  end

  email 'first_event', renders: %i[first_event], source: 'models/concerns/account_notifications.rb' do
    sent { attendee.send_first_event_email_without_delay }
  end

  email 'stripe subscription created', source: 'models/concerns/account_notifications.rb' do
    admin
    sent { attendee.send_stripe_subscription_created_notification(api_object(plan: api_object(amount: 500, currency: 'gbp'))) }
  end

  email 'stripe subscription deleted', source: 'models/concerns/account_notifications.rb' do
    admin
    sent { attendee.send_stripe_subscription_deleted_notification(api_object(plan: api_object(amount: 500, currency: 'gbp'))) }
  end

  email 'message', renders: %i[message], unsubscribe: true do
    attendee.set(email_confirmed: true, can_message: true)
    message = Message.create!(messenger: attendee, messengee: admin, body: "Hello\nthere")
    sent { message.send_email_without_delay }
  end

  email 'account contribution', source: 'models/account_contribution.rb' do
    admin
    contribution = AccountContribution.create!(account: attendee, amount: 5, currency: 'GBP', source: 'Donate page')
    sent { contribution.send_notification_without_delay }
  end

  # Events

  email 'event_submission', renders: %i[event_submission] do
    event_with_admin
    sent { @event.send_public_submission_notification_without_delay }
  end

  email 'event_destroyed', renders: %i[event_destroyed] do
    event_with_admin
    sent { @event.send_destroy_notification(admin) }
  end

  email 'reminder', renders: %i[reminder _tickets_table], unsubscribe: true do
    event_with_admin(reminder_hours_before: 24)
    free_order
    paid_order(FactoryBot.create(:account, name: 'Paying Person'))
    emails = sent { @event.send_reminders_without_delay(:all) }
    assert_equal 2, emails.count { |email| email.recipients.any? }, 'a reminder with and without the Cancel your RSVP link'
  end

  email 'reminder_starred', renders: %i[reminder_starred _tickets_table], unsubscribe: true do
    event_with_admin
    @event.event_stars.create!(account: attendee)
    sent { @event.send_star_reminders_without_delay(:all) }
  end

  email 'feedback', renders: %i[feedback], unsubscribe: true do
    event_with_admin(feedback_questions: 'How was it?')
    free_order
    sent { @event.send_feedback_requests_without_delay(:all) }
  end

  email 'event_feedback', renders: %i[event_feedback] do
    event_feedback = feedback
    sent { event_feedback.send_feedback_without_delay }
  end

  email 'event_feedback anonymous', renders: %i[event_feedback] do
    event_feedback = feedback(anonymous: true)
    sent { event_feedback.send_feedback_without_delay }
  end

  email 'event_feedback_response', renders: %i[event_feedback_response] do
    event_feedback = feedback
    event_feedback.set(response: 'Thank you!')
    sent { event_feedback.send_response_without_delay }
  end

  email 'event_feedback_destroyed', renders: %i[event_feedback_destroyed] do
    event_feedback = feedback
    sent { event_feedback.send_destroy_notification_without_delay(admin) }
  end

  email 'waitlist', renders: %i[waitlist] do
    event_with_admin
    waitship = @event.waitships.create!(account: attendee)
    sent { waitship.send_notification_without_delay }
  end

  email 'waitlist for a ticket type', renders: %i[waitlist] do
    event_with_admin(allow_ticket_type_waitlists: true)
    ticket_type_waitship = @event.ticket_types.first.ticket_type_waitships.new(account: attendee)
    ticket_type_waitship.save!(validate: false)
    sent { ticket_type_waitship.send_notification_without_delay }
  end

  email 'waitlist_tickets_available', renders: %i[waitlist_tickets_available] do
    event_with_admin
    @event.waitships.create!(account: attendee)
    sent { @event.send_waitlist_tickets_available_without_delay }
  end

  email 'waitlist_tickets_available for a ticket type', renders: %i[waitlist_tickets_available] do
    event_with_admin(allow_ticket_type_waitlists: true)
    ticket_type = @event.ticket_types.first
    ticket_type.ticket_type_waitships.new(account: attendee).save!(validate: false)
    sent { @event.send_ticket_type_waitlist_tickets_available_without_delay(ticket_type.id) }
  end

  email 'event boost', source: 'models/event_boost.rb' do
    admin
    event_with_admin
    boost = FactoryBot.create(:event_boost, event: @event)
    sent { boost.send_admin_notification_without_delay }
  end

  # Orders and tickets

  email 'order', renders: %i[order] do
    event_with_admin
    order = free_order(answers: [['Dietary requirements', "None\nreally"], ['[checkbox] Photos OK?', true]])
    sent { order.send_notification_without_delay }
  end

  email 'tickets', renders: %i[tickets _tickets_table] do
    ticket_email_organisation
    event_with_admin(extra_info_for_ticket_email: '<p>Bring a blanket</p>')
    order = free_order
    sent { order.send_tickets_without_delay }
  end

  email 'tickets for an evergreen event', renders: %i[tickets _tickets_table] do
    admin
    ticket_email_organisation
    create_event(:evergreen, prices: [0])
    order = free_order
    sent { order.send_tickets_without_delay }
  end

  email 'tickets for a ticketholder', renders: %i[tickets _tickets_table] do
    ticket_email_organisation
    event_with_admin
    ticket = free_order.tickets.first
    ticket.set(email: 'holder@example.com', name: 'Holder Person')
    sent { ticket.send_ticket_without_delay }
  end

  email 'rsvp_cancelled', renders: %i[rsvp_cancelled] do
    event_with_admin
    order = free_order
    sent { Order.send_rsvp_cancelled_email(@event.id.to_s, order.rsvp_cancelled_recipients) }
  end

  email 'purchase_failed', renders: %i[purchase_failed _purchase_error] do
    event_with_admin
    order = paid_order
    sent { order.notify_of_failed_purchase(Stripe::CardError.new('Your card was declined.', 'card_declined'), provider: 'Stripe', help: 'Check your Stripe dashboard.') }
  end

  email 'refund', renders: %i[refund] do
    event_with_admin
    order = paid_order
    sent { order.notify_of_refund(amount: 10) }
  end

  email 'refund_failed_order', renders: %i[refund_failed_order] do
    event_with_admin
    order = paid_order
    sent { order.notify_of_failed_refund(StandardError.new('No such charge: https://dashboard.stripe.com/payments/ch_1')) }
  end

  email 'refund_failed_ticket', renders: %i[refund_failed_ticket] do
    event_with_admin
    ticket = paid_order.tickets.first
    sent { ticket.notify_of_failed_refund(StandardError.new('No such charge')) }
  end

  email 'ticket_email_update', renders: %i[ticket_email_update] do
    event_with_admin
    ticket = free_order.tickets.first
    ticket.set(email: 'holder@example.com')
    sent { ticket.send_email_update_notification }
  end

  email 'ticket_resale', renders: %i[ticket_resale] do
    event_with_admin
    ticket = paid_order.tickets.first
    previous_account = FactoryBot.create(:account, name: 'Previous Holder')
    sent do
      ticket.send_resale_notification_to_organiser(previous_account)
      ticket.send_resale_notification_to_organiser(previous_account, requires_manual_refund: true, gocardless_instalment: true, refund_amount: 10, currency: 'GBP')
      ticket.send_resale_notification_to_organiser(previous_account, requires_manual_refund: true, refund_amount: 10, order_total: 5, currency: 'GBP')
    end
  end

  email 'ticket_resale_previous_ticketholder', renders: %i[ticket_resale_previous_ticketholder] do
    event_with_admin
    ticket = paid_order.tickets.first
    previous_account = FactoryBot.create(:account, name: 'Previous Holder')
    sent do
      ticket.send_resale_notification_to_previous_ticketholder(previous_account)
      ticket.send_resale_notification_to_previous_ticketholder(previous_account, requires_manual_refund: true, gocardless_instalment: true)
    end
  end

  # Organisations, activities and local groups

  email 'csv', renders: %i[csv] do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    activity.activity_applications.create!(account: attendee, status: 'Pending')
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    local_group.local_groupships.create!(account: attendee)
    emails = sent do
      @organisation.send_followers_csv_without_delay(@account)
      activity.send_applications_csv_without_delay(@account)
      activity.send_followers_csv_without_delay(@account, :activityships)
      local_group.send_followers_csv_without_delay(@account, :local_groupships)
    end
    assert_equal [['followers.csv'], ['applications.csv'], ['followers.csv'], ['followers.csv']], emails.select { |email| email.subject_line == 'Dandelion CSV export' }.map(&:attachment_names)
  end

  email 'activity_application', renders: %i[activity_application] do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    application = activity.activity_applications.create!(account: attendee, status: 'Pending', answers: [['Why?', 'Because']])
    sent { application.send_notification_without_delay }
  end

  email 'accepted', renders: %i[accepted] do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, email: 'activity@example.com', extra_info_for_acceptance_email: '<p>See you soon</p>')
    application = activity.activity_applications.create!(account: attendee, status: 'Pending')
    sent { application.accept }
  end

  email 'new_monthly_donor', renders: %i[new_monthly_donor] do
    organisationship = organisationship_with_donation
    sent { @organisation.send_new_monthly_donor_notification(organisationship) }
  end

  email 'finished_monthly_donor', renders: %i[finished_monthly_donor] do
    organisationship = organisationship_with_donation
    sent { @organisation.send_finished_monthly_donor_notification(organisationship) }
  end

  email 'insufficient_funds_topup', renders: %i[insufficient_funds_topup] do
    create_organisation
    sent { @organisation.send_insufficient_funds_topup_notification_without_delay }
  end

  email 'organisation contribution', source: 'models/organisation_contribution.rb' do
    admin
    create_organisation
    contribution = @organisation.organisation_contributions.create!(amount: 10, currency: 'GBP', payment_completed: true)
    sent { contribution.send_notification_without_delay }
  end

  email 'organisation welcome', source: 'models/organisationship.rb' do
    create_organisation(welcome_from: 'Organisation <hello@mg.example.com>', welcome_subject: 'Welcome!', welcome_body: '<p>Hi %recipient.firstname%, welcome</p>')
    # Before the organisation has a Mailgun account, or joining would send the welcome there and then
    organisationship = @organisation.organisationships.create!(account: attendee)
    @organisation.set(mailgun_api_key: 'key-test', mailgun_domain: 'mg.example.com')
    sent { organisationship.send_welcome(force: true) }
  end

  email 'organisation monthly donation welcome', source: 'models/organisationship.rb' do
    organisationship = organisationship_with_donation
    @organisation.set(monthly_donation_welcome_from: 'Organisation <hello@mg.example.com>', monthly_donation_welcome_subject: 'Thank you!',
                      monthly_donation_welcome_body: '<p>[1-10] Thanks for your small gift</p><p>[10+] Thanks for your big gift</p>',
                      mailgun_api_key: 'key-test', mailgun_domain: 'mg.example.com')
    sent { Organisationship.find(organisationship.id).send_monthly_donation_welcome(force: true) }
  end

  # Gatherings and discussions

  email 'notification', renders: %i[notification], unsubscribe: true do
    gathering_member
    notifications = Notification.and(:type.in => Notification.mailable_types)
    assert notifications.exists?
    sent { notifications.each(&:send_email_without_delay) }
  end

  email 'gathering welcome', source: 'models/membership.rb' do
    member = gathering_member
    sent { @gathering.memberships.find_by(account: member).send_email_without_delay }
  end

  email 'comment', renders: %i[comment], unsubscribe: true do
    member = gathering_member
    [member, @account].each { |account| account.set(has_signed_in: true) }
    post = @gathering.teams.find_by(name: 'General').posts.create!(account: member, subject: 'Rota')
    post.comments.create!(account: member, body: 'First thoughts')
    comment = post.comments.create!(account: @account, body: "Second\nthoughts")
    sent { comment.send_comment_without_delay }
  end

  # Admins and the founder

  email 'mailgun delivery stats', source: 'lib/mail/mailgun_delivery_stats.rb' do
    admin
    with_env('MAILGUN_API_KEY' => 'key-test', 'MAILGUN_REGION' => 'api.eu.mailgun.net', 'MAILGUN_NOTIFICATIONS_HOST' => 'notifications.example.com') do
      low = { by_provider: [{ label: 'Gmail', delivered_count: 100, bounced_count: 10, delivered_rate_f: 0.8 }] }
      [low, { error: 'Mailgun is down' }].each do |result|
        MailgunDeliveryStats.stub(:fetch, result) { sent { MailgunDeliveryStats.check_and_notify } }
      end
      assert_equal 2, @sent_emails.length
    end
  end

  email 'ASN blocked', source: 'lib/security/asn.rb' do
    with_env('FOUNDER_EMAIL' => 'founder@example.com') do
      sent { Asn.notify_asn_blocked(12_345, { bot: 90, bar: 50, ratio: 2 }) }
    end
  end

  email 'feedback to the founder', source: 'app/app.rb' do
    sign_in_with_rack(attendee)
    with_env('FOUNDER_EMAIL' => 'founder@example.com') do
      sent { post '/feedback', feedback: 'Lovely site' }
    end
    assert last_response.ok?
  end

  email 'question to the founder', source: 'app/controllers/docs.rb' do
    sign_in_with_rack(attendee)
    with_env('FOUNDER_EMAIL' => 'founder@example.com') do
      sent { post '/docs/question', question: 'How do refunds work?' }
    end
    assert last_response.ok?
  end

  email 'referral reward claim', source: 'app/app.rb' do
    admin
    create_organisation(referrer: attendee)
    @organisation.organisation_contributions.create!(amount: 200, currency: 'EUR', payment_completed: true)
    sign_in_with_rack(attendee)
    sent { post "/referrals/#{@organisation.id}/claim" }
    assert last_response.redirect?
  end

  test 'the feedback summary email renders, though nothing sends it' do
    attendee.set(feedback_summary: 'People loved it.')
    document = Nokogiri::HTML(EmailHelper.html(:feedback_summary, account: attendee))
    document.css('style, head').each(&:remove)
    assert_includes document.text, 'People loved it.'
    PLACEHOLDERS.each { |pattern| refute_match pattern, document.text.squish }
    assert_links_absolute(document, 'feedback_summary')
  end

  test 'every template is sent by a case, or says why not' do
    templates = Dir[File.join(TEMPLATES_DIR, '**/*.erb')].map { |path| path.delete_prefix("#{TEMPLATES_DIR}/").delete_suffix('.erb') }
    covered = self.class.cases.values.flat_map { |kase| kase[:renders] }.uniq

    assert_empty templates - covered - NOT_SENT.keys, 'Add a case for each new email template, or say in NOT_SENT why there is none'
    assert_empty (covered + NOT_SENT.keys) - templates, 'A case or NOT_SENT names a template that is gone'
    assert_empty covered & NOT_SENT.keys
  end

  test 'every Mailer.deliver without a template, and every send_to_founder, is sent by a case' do
    calls = Dir[Padrino.root('{app,models,lib,tasks,config}/**/*.{rb,rake,erb}')].each_with_object(Hash.new(0)) do |path, counts|
      file = path.delete_prefix("#{Padrino.root}/")
      next if file == 'lib/mail/mailer.rb'

      source = File.read(path).gsub(/^\s*#.*$/, '')
      # send_to_founder's own Mailer.deliver is counted at its callers
      count = file == 'lib/mail/email_helper.rb' ? 0 : source.scan(/Mailer\.deliver\((?!\s*:)/).length
      count += source.scan(/(?<!def self\.)send_to_founder\(/).length
      counts[file] = count if count.positive?
    end
    cases = self.class.cases.values.filter_map { |kase| kase[:source] }.tally

    assert_equal calls.sort.to_h, cases.sort.to_h, 'Add a case (source: its file) for each Mailer.deliver with content:, html: or text:'
  end
end
