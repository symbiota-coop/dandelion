require_relative '../test_config'

# Mailer.deliver, the one way emails are sent (lib/mail/mailer.rb)
class MailerTest < ActiveSupport::TestCase
  MAILGUN_ENV = {
    'MAILGUN_API_KEY' => 'key-dandelion', 'MAILGUN_REGION' => 'api.eu.mailgun.net',
    'MAILGUN_NOTIFICATIONS_HOST' => 'notifications.example.com', 'MAILGUN_TICKETS_HOST' => 'tickets.example.com',
    'MAILGUN_PMAILS_HOST' => 'pmails.example.com', 'MAILGUN_POSTS_HOST' => 'posts.example.com', 'MAILGUN_MICROSOFT_HOST' => 'microsoft.example.com',
    'NOTIFICATIONS_EMAIL_FULL' => 'Dandelion <notifications@example.com>', 'TICKETS_EMAIL_FULL' => 'Dandelion <tickets@example.com>'
  }.freeze

  class FailingEmail < RecordedEmail
    def finalize
      raise Mailgun::CommunicationError, 'Mailgun is down'
    end
  end

  # What one Mailer.deliver makes: [[the API key and host its client got], the Mailgun domain, the RecordedEmail], with
  # the Mailgun ENV set, in the Padrino env given
  def delivery(env: :test, email: RecordedEmail.new, extra_env: {}, **options)
    made = nil
    with_env(MAILGUN_ENV.merge(extra_env)) do
      Padrino.stub(:env, env) do
        Mailgun::Client.stub(:new, ->(*args) { args }) do
          Mailgun::BatchMessage.stub(:new, ->(client, host) { email.tap { made = [client, host, email] } }) do
            Mailer.deliver(**{ to: 'someone@example.com', subject: 'Hello', html: '<p>Hello</p>' }.merge(options))
          end
        end
      end
    end
    made
  end

  # Unsaved: an organisation can't be saved with only some of its Mailgun details, and Mailer only reads them
  def mailgun_organisation(**attrs)
    Organisation.new(mailgun_domain: 'mg.organisation.example', **attrs)
  end

  test 'an account is sent its first name or there, a sign in token and its id' do
    named = FactoryBot.create(:account, name: 'Maria Sabina')
    nameless = FactoryBot.create(:account, name: 'Placeholder').tap { |account| account.set(name: nil) }

    email = recorded_email { Mailer.deliver(to: [named, nameless], subject: 'Hello', text: 'Hello') }

    assert_equal [named.email, nameless.email], email.recipients
    assert_equal({ 'firstname' => 'Maria', 'token' => named.reload.link_token, 'id' => named.id.to_s }, email.variables[named.email])
    assert_equal 'there', email.variables[nameless.email]['firstname']
    assert_equal 'Hello', email.text
  end

  test 'recipients can be an email alone, given no variables, or an email and its own variables' do
    account = FactoryBot.create(:account)

    assert_equal [['a@example.com', nil]], Mailer.recipients('a@example.com')
    assert_equal [['a@example.com', { 'firstname' => 'Ada' }]], Mailer.recipients(['a@example.com', { 'firstname' => 'Ada' }])
    assert_equal [['a@example.com', nil], ['b@example.com', { 'id' => '1' }]], Mailer.recipients(['a@example.com', ['b@example.com', { 'id' => '1' }]])
    assert_equal [account.mail_recipient], Mailer.recipients(Account.and(id: account.id))
    assert_equal [[account.email, account.mail_variables.merge('when' => 'soon')]], Mailer.recipients([account.mail_recipient('when' => 'soon')])
  end

  test 'each stream sends from its own Mailgun domain, and notifications and tickets from their own sender' do
    client, host, email = delivery
    assert_equal ['key-dandelion', 'api.eu.mailgun.net'], client
    assert_equal 'notifications.example.com', host
    assert_equal 'Dandelion <notifications@example.com>', email.sender

    _, host, email = delivery(stream: :tickets)
    assert_equal 'tickets.example.com', host
    assert_equal 'Dandelion <tickets@example.com>', email.sender

    _, host, email = delivery(stream: :posts, from: 'Dandelion <post@posts.example.com>')
    assert_equal 'posts.example.com', host
    assert_equal 'Dandelion <post@posts.example.com>', email.sender

    _, host, = delivery(stream: :pmails, from: 'mailer@pmails.example.com')
    assert_equal 'pmails.example.com', host

    _, _, email = delivery(from: 'Someone <someone@example.com>', reply_to: 'reply@example.com')
    assert_equal 'Someone <someone@example.com>', email.sender
    assert_equal 'reply@example.com', email.reply_to_address
  end

  test 'From and Reply-To, which carry organiser text, cannot open a recipient token' do
    # Mailgun fills variables into both headers (tested Nov 2026): an event's contact email of
    # %recipient.token%@attacker.example would send each buyer's token there when they reply
    email = Mailgun::BatchMessage.new(Mailgun::Client.new('key'), 'example.com') # rubocop:disable Dandelion/MailgunDirect -- tests EmailHelper::RecipientVariables on a real BatchMessage, which sends nothing
    delivery(email: email, to: ['someone@example.com', { 'firstname' => 'Ada', 'token' => 'SECRET' }],
             from: 'Org %recipient.token% <tickets@example.com>', reply_to: '%recipient.token%@attacker.example')
    variables = email.recipient_variables['someone@example.com']

    [Array(email.message[:from]).last, email.message['h:reply-to']].each do |header|
      assert_includes header, 'recipient.token'
      refute_includes EmailFields.replace_recipient_variables(header, variables), 'SECRET'
    end
  end

  test 'the Microsoft workaround sends to Microsoft addresses from its own domain, only where asked and only when it is on' do
    on = { 'MICROSOFT_EMAIL_WORKAROUND' => '1' }

    assert_equal 'microsoft.example.com', delivery(to: 'someone@Hotmail.co.uk', stream: :tickets, microsoft_workaround: true, extra_env: on)[1]
    assert_equal 'tickets.example.com', delivery(to: 'someone@example.com', stream: :tickets, microsoft_workaround: true, extra_env: on)[1]
    assert_equal 'tickets.example.com', delivery(to: 'someone@outlook.com', stream: :tickets, microsoft_workaround: true)[1]
    assert_equal 'notifications.example.com', delivery(to: 'someone@outlook.com', extra_env: on)[1]
  end

  test 'emails are sent in production only, and return what Mailgun says it sent' do
    refute delivery[2].finalized?
    assert delivery(env: :production)[2].finalized?

    email = RecordedEmail.new
    email.define_singleton_method(:finalize) { { 'message-id' => 1 } }
    with_env(MAILGUN_ENV) do
      Padrino.stub(:env, :production) do
        Mailgun::BatchMessage.stub(:new, email) do
          assert_equal({ 'message-id' => 1 }, Mailer.deliver(to: 'someone@example.com', subject: 'Hello', text: 'Hello'))
        end
      end
    end
  end

  test 'send_when: :configured sends wherever there is a Mailgun API key' do
    assert delivery(send_when: :configured)[2].finalized?
    refute delivery(send_when: :configured, extra_env: { 'MAILGUN_API_KEY' => nil })[2].finalized?
  end

  test 'nothing is sent to no one' do
    refute delivery(env: :production, to: [])[2].finalized?
  end

  test 'via: an organisation sends through its own Mailgun account, whenever it has a key' do
    client, host, email = delivery(via: mailgun_organisation(mailgun_api_key: 'key-organisation', mailgun_region: 'EU'), from: 'Org <hello@mg.organisation.example>')
    assert_equal ['key-organisation', 'api.eu.mailgun.net'], client
    assert_equal 'mg.organisation.example', host
    assert email.finalized?

    client, _, email = delivery(via: mailgun_organisation(mailgun_api_key: nil), from: 'Org <hello@mg.organisation.example>')
    assert_equal [nil, 'api.mailgun.net'], client
    refute email.finalized?
  end

  test 'attachments are sent with their names from tempfiles that are gone afterwards, even when sending fails' do
    paths = []
    new_tempfile = Tempfile.method(:new)
    Tempfile.stub(:new, ->(*args) { new_tempfile.call(*args).tap { |file| paths << file.path } }) do
      email = delivery(attachments: { 'ticket.pdf' => '%PDF-1.4', 'event.ics' => 'BEGIN:VCALENDAR' })[2]
      assert_equal ['ticket.pdf', 'event.ics'], email.attachment_names
      assert_equal(%w[.pdf .ics], paths.map { |path| File.extname(path) })

      assert_raises(Mailgun::CommunicationError) { delivery(env: :production, email: FailingEmail.new, attachments: { 'export.csv' => 'a,b' }) }
    end

    assert_equal 3, paths.size
    paths.each { |path| refute File.exist?(path), "#{path} is left behind" }
    assert_empty Dir.glob('*.{pdf,ics,csv}')
  end
end
