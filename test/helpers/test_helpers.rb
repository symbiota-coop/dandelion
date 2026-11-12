# Helpers more than one test file uses, included in every test (test/test_config.rb). A helper only one file uses
# stays in that file, and one the files on a subject share goes in a module here named for what it holds

# Stands in for Mailgun::BatchMessage, keeping what an email would say: its recipients and their recipient variables,
# subject, HTML or text, sender, reply-to and attachments' filenames, and whether it was sent (finalized?)
class RecordedEmail
  attr_reader :recipients, :variables, :subject_line, :html, :text, :attachment_names, :sender, :reply_to_address

  def initialize
    @recipients = []
    @variables = {}
    @attachment_names = []
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
