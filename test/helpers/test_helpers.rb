# Helpers more than one test file uses, included in every test (test/test_config.rb). A helper only one file uses
# stays in that file, and one the files on a subject share goes in a module here named for what it holds

# Stands in for Mailgun::BatchMessage, keeping what an email would say: its recipients and their recipient variables,
# subject, HTML or text, sender, reply-to, attachments' filenames, tags and headers, and whether it was sent (finalized?)
class RecordedEmail
  attr_reader :recipients, :variables, :subject_line, :html, :text, :attachment_names, :sender, :reply_to_address, :tags, :headers

  def initialize
    @recipients = []
    @variables = {}
    @attachment_names = []
    @tags = []
    @headers = {}
    @finalized = false
  end

  def add_recipient(_type, email, variables = {})
    @recipients << email
    @variables[email] = variables
  end

  def subject(text)
    @subject_line = text
  end

  def body_html(html)
    @html = html
  end

  def body_text(text)
    @text = text
  end

  def add_attachment(_file, filename = nil)
    @attachment_names << filename
  end

  def from(address)
    @sender = address
  end

  def reply_to(address)
    @reply_to_address = address
  end

  def add_tag(tag)
    @tags << tag.to_s
  end

  def header(name, value)
    @headers[name] = value
  end

  def finalize
    @finalized = true
    nil
  end

  def finalized? = @finalized
end

module TestHelpers
  # Factory accounts are unconfirmed, and a code from a new browser would confirm one as someone else (Account#confirm_email!),
  # signing out its other sessions and resetting its password: confirm: false to test that
  def sign_in(account, confirm: true)
    account.set(email_confirmed: true) if confirm
    Capybara.reset_sessions!
    # From a fresh copy: signing in uses the code up in the database, and the account in hand would offer it again
    visit "/?sign_in_code=#{Account.find(account.id).issue_sign_in_code!}"
  end

  def sign_in_with_rack(account, confirm: true)
    account.set(email_confirmed: true) if confirm
    clear_cookies
    get '/', sign_in_code: Account.find(account.id).issue_sign_in_code!
    follow_redirect! while last_response.redirect?
  end

  # Helpers set @account/@organisation/@event/@gathering. Inline FactoryBot/Event.new uses locals.
  def create_organisation(*traits, **attrs)
    @account ||= FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, *traits, account: @account, **attrs)
  end

  def create_event(*traits, as: :event, **attrs)
    create_organisation unless @organisation
    instance_variable_set(:"@#{as}", FactoryBot.create(:event, *traits, organisation: @organisation, **attrs))
  end

  # A new account, with these attributes, who admins only event, as its facilitator
  def create_facilitator(event, **attrs)
    FactoryBot.create(:account, **attrs).tap { |account| event.event_facilitations.create!(account: account) }
  end

  def create_gathering(*traits, **attrs)
    @account ||= FactoryBot.create(:account)
    @gathering = FactoryBot.create(:gathering, *traits, account: @account, **attrs)
  end

  def create_full_event_hierarchy(options = {})
    create_organisation(**options.fetch(:organisation_options, {}))
    @activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'open')
    @local_group = FactoryBot.create(:local_group, organisation: @organisation)

    event_attrs = options.fetch(:event_options, {}).dup
    event_attrs[:activity] = @activity unless options[:skip_activity]
    event_attrs[:local_group] = @local_group unless options[:skip_local_group]
    create_event(**event_attrs)
  end

  def assert_associated(entity, account, association_name)
    assert entity.send(association_name).find_by(account: account),
           "Expected #{account.email} to be associated with #{entity.class.name} '#{entity.try(:name) || entity.id}'"
  end

  def assert_cannot_reassign_organisation_or_account(record)
    other_account = FactoryBot.create(:account)
    other_organisation = FactoryBot.create(:organisation, account: other_account)
    record.organisation = other_organisation
    record.account = other_account
    refute record.valid?
    assert_includes record.errors[:organisation], 'cannot be changed'
    assert_includes record.errors[:account], 'cannot be changed'
  end

  # A stand-in for an API object (a Stripe session, a GoCardless billing request) that answers the attributes it's
  # given and nothing else, so a test fails loudly if the code reads one it didn't set
  def api_object(**attributes)
    Struct.new(*attributes.keys).new(*attributes.values)
  end

  # A Stripe payment intent with one charge, of amount and amount_refunded cents. The default is more than any test's
  # refund, so refunds aren't capped at what's left unless a test sets it. With an application_fee (its id), the
  # charge answers that too
  def stripe_payment_intent(charge_id, amount: 1_000_000, amount_refunded: 0, application_fee: nil)
    charge = { id: charge_id, amount: amount, amount_refunded: amount_refunded }
    charge[:application_fee] = application_fee if application_fee
    api_object(charges: [api_object(**charge)])
  end

  # Sets these ENV variables while the block runs, then puts back what they were (nil unsets one). .env.test has no
  # Mailgun or recaptcha settings, for instance
  def with_env(vars)
    previous = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous&.each { |key, value| ENV[key] = value }
  end

  # Stubs Dragonfly's shell, failing the test if the block hands a file to ImageMagick
  # Real ImageMagick, for a test of ImageMagick itself (test/setup/fake_imagemagick.rb fakes it for the rest)
  def with_imagemagick
    FakeImageMagick.real = true
    yield
  ensure
    FakeImageMagick.real = false
  end

  def without_imagemagick(&)
    Dragonfly.app.shell.stub(:run, ->(command, *) { flunk "ran #{command}" }, &)
  end

  # Requests

  # A request as a page's pagelets make it, which a refusal answers with 403 rather than a redirect. env adds to the
  # Rack env it's sent with
  def xhr(method, path, params = {}, env = {})
    send(method, path, params, env.merge('HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'))
  end

  def xhr_get(path, params = {}, env = {})
    xhr(:get, path, params, env)
  end

  def assert_redirected_to(path)
    assert last_response.redirect?, "Expected a redirect to #{path}, got #{last_response.status}"
    assert_equal path, URI(last_response.location).path
  end

  # Emails

  # The emails the block would send, one per Mailgun::BatchMessage it makes
  def recorded_emails(&)
    emails = []
    Mailgun::BatchMessage.stub(:new, ->(*) { RecordedEmail.new.tap { |email| emails << email } }, &)
    emails
  end

  # The one email the block would send, for blocks that send at most one
  def recorded_email(&)
    email = RecordedEmail.new
    Mailgun::BatchMessage.stub(:new, email, &)
    email
  end

  # The emails the queued jobs with this handler would send, running them
  def emails_sent_by_jobs(handler)
    recorded_emails { Delayed::Job.and(handler: handler).each(&:invoke_job) }
  end

  # A Mailgun webhook's click event for pmail at url from a device_type, signed with key
  def mailgun_click_event(pmail, key:, url: 'https://example.com/page', device_type: nil)
    timestamp = Time.now.to_i.to_s
    token = SecureRandom.hex(25)
    {
      'signature' => { 'timestamp' => timestamp, 'token' => token, 'signature' => OpenSSL::HMAC.hexdigest('SHA256', key, "#{timestamp}#{token}") },
      'event-data' => { 'event' => 'clicked', 'tags' => [pmail.id.to_s], 'url' => url, 'client-info' => { 'device-type' => device_type } }
    }.to_json
  end

  # Stripe

  # Stripe Checkout gives this session for any checkout the block starts, and the block is given it
  def with_stubbed_stripe_session(session_id: 'cs_test', payment_intent: 'pi_test')
    session = api_object(id: session_id, payment_intent: payment_intent, url: 'https://checkout.stripe.com/test')
    Stripe::Checkout::Session.stub(:create, session) { yield session }
  end

  # Stripe.js would take the buyer to stripe.com with the session: record which on the page instead, for
  # has_checkout_session? to check
  def record_stripe_redirect
    execute_script 'window.Stripe = function () { return { redirectToCheckout: function (options) { document.body.dataset.checkoutSession = options.sessionId } } }'
  end

  def has_checkout_session?(session_id)
    page.has_css? "body[data-checkout-session='#{session_id}']"
  end

  # The body of a Stripe webhook's checkout.session.completed event (or another type) for session_id
  def checkout_completed_payload(session_id, type: 'checkout.session.completed', payment_status: 'paid')
    { id: "evt_#{SecureRandom.hex(4)}", object: 'event', type: type, data: { object: { id: session_id, object: 'checkout.session', payment_status: payment_status } } }.to_json
  end

  # Gatherings

  # A new account, a member of @gathering
  def create_member(name: 'Member Person', **attrs)
    FactoryBot.create(:account, name: name, **attrs).tap { |account| @gathering.memberships.create!(account: account) }
  end

  def gathering_path(path = '')
    "/g/#{@gathering.slug}#{path}"
  end

  # Buttons and links that ask first, in a popover whose button is named label. The popover hangs off the page, outside
  # any within block

  def click_link_and_confirm(label)
    click_link label
    page.document.find('.popover').click_button label
  end

  def click_button_and_confirm(label, button: label)
    click_button button
    page.document.find('.popover').click_button label
  end

  # Waits for something a request from the page does, such as a field that saves when it changes, to be done
  def wait_until(message)
    page.document.synchronize { raise Capybara::ExpectationNotMet, message unless yield }
  end

  # Signing up

  # Fills in and sends the sign up form, in the browser, as account
  def fill_signup_form(account)
    fill_in 'Full name', with: account.name
    fill_in 'Email', with: account.email
    fill_in 'Location', with: account.location
    click_button 'Sign up'
  end

  # Posts the sign up form, through Rack, as account
  def post_new_account(account, extra = {})
    post '/accounts/new', {
      account: { name: account.name, email: account.email, location: account.location },
      recaptcha_skip_secret: ENV['RECAPTCHA_SKIP_SECRET']
    }.merge(extra)
  end
end
