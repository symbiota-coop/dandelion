require_relative '../test_config'
require_relative '../helpers/checkout_webhook_helpers'

# Stripe checkout webhooks, WhatsApp verification and Mailgun webhooks
class WebhooksTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include CheckoutWebhookHelpers

  def checkout_completed_event(session_id, type: 'checkout.session.completed', payment_status: 'paid')
    Stripe::Event.construct_from(
      {
        id: 'evt_test',
        type: type,
        data: { object: { id: session_id, payment_status: payment_status } }
      }
    )
  end

  test 'checkout.session.completed with unpaid status does not complete the order until async payment succeeds' do
    create_organisation(stripe_endpoint_secret: 'whsec_test')
    create_event(prices: [10])
    order = create_incomplete_order(@event, value: 10, session_id: "cs_#{SecureRandom.hex(4)}")

    deliver_stripe_webhook(@organisation, checkout_completed_event(order.session_id, payment_status: 'unpaid'))
    refute order.reload.payment_completed?

    deliver_stripe_webhook(@organisation, checkout_completed_event(order.session_id, type: 'checkout.session.async_payment_succeeded'))
    assert order.reload.payment_completed?
  end

  def deliver_stripe_webhook(organisation, stripe_event)
    Stripe::Webhook.stub :construct_event, stripe_event do
      header 'Stripe-Signature', 'sig'
      post "/o/#{organisation.slug}/stripe_webhook"
    end
  end

  def create_stripe_event(ticket_quantity: 10)
    create_organisation(stripe_endpoint_secret: 'whsec_test')
    create_event(prices: [10])
    @event.ticket_types.first.set(quantity: ticket_quantity)
  end

  def post_stripe_purchase(event, account)
    ticket_type = event.ticket_types.first
    header 'Accept', 'application/json'
    post "/e/#{event.slug}/purchase",
         ticketForm: { quantities: { ticket_type.id.to_s => '1' } },
         detailsForm: {
           payment_method: 'stripe',
           account: { name: account.name, email: account.email }
         }
  end

  test 'checkout.session.completed webhook restores a deleted checkout' do
    create_organisation(stripe_endpoint_secret: 'whsec_test')
    create_event(prices: [10])
    order = create_incomplete_order(@event, value: 10, session_id: "cs_#{SecureRandom.hex(4)}")
    session_id = order.session_id
    order.destroy

    deliver_stripe_webhook(@organisation, checkout_completed_event(session_id))

    restored = Order.find(order.id)
    assert restored
    assert restored.payment_completed?
    assert restored.tickets.first
    assert restored.tickets.first.payment_completed?
  end

  test 'stripe purchase creates an incomplete order then webhook issues the ticket' do
    create_stripe_event
    buyer = FactoryBot.create(:account)

    with_stubbed_stripe_session do
      post_stripe_purchase(@event, buyer)
    end

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'cs_test', body['session_id']

    order = @event.orders.find_by(session_id: 'cs_test')
    assert order
    refute order.payment_completed?
    refute order.tickets.first.payment_completed?

    deliver_stripe_webhook(@organisation, checkout_completed_event(order.session_id))

    assert order.reload.payment_completed?
    assert order.tickets.first.reload.payment_completed?
  end

  test 'stripe purchase with quantity 1 sells out and rejects a second purchase' do
    create_stripe_event(ticket_quantity: 1)
    buyer = FactoryBot.create(:account)
    other = FactoryBot.create(:account)

    with_stubbed_stripe_session do
      post_stripe_purchase(@event, buyer)
    end

    assert_equal 200, last_response.status
    order = @event.orders.find_by(session_id: 'cs_test')
    assert order
    refute order.payment_completed?
    assert @event.reload.sold_out_cache
    assert @event.ticket_types.first.reload.sold_out_cache

    with_stubbed_stripe_session(session_id: 'cs_other') do
      post_stripe_purchase(@event, other)
    end

    assert_equal 400, last_response.status
    assert_equal 1, @event.orders.count
    assert_equal 1, @event.tickets.count

    deliver_stripe_webhook(@organisation, checkout_completed_event(order.session_id))

    assert order.reload.payment_completed?
    assert @event.reload.sold_out_cache
    assert_equal 1, @event.tickets.complete.count
  end

  def with_whatsapp_verify_token(value, &)
    with_env({ 'WHATSAPP_VERIFY_TOKEN' => value }, &)
  end

  test 'whatsapp verification is refused when no verify token is configured' do
    with_whatsapp_verify_token(nil) do
      get '/whatsapp', 'hub.challenge' => '<script>alert(1)</script>'
    end
    assert_equal 403, last_response.status
    refute_includes last_response.body, '<script>'
  end

  test 'whatsapp verification is refused with the wrong verify token' do
    with_whatsapp_verify_token('right-token') do
      get '/whatsapp', 'hub.verify_token' => 'wrong-token', 'hub.challenge' => '123'
    end
    assert_equal 403, last_response.status
  end

  test 'whatsapp verification echoes the challenge as plain text' do
    with_whatsapp_verify_token('right-token') do
      get '/whatsapp', 'hub.verify_token' => 'right-token', 'hub.challenge' => '<b>123</b>'
    end
    assert_equal 200, last_response.status
    assert_equal '<b>123</b>', last_response.body
    assert_match %r{\Atext/plain}, last_response.content_type
  end

  def with_local_stylesheet
    file = Tempfile.new(['premailer', '.css'])
    file.write('p { font-family: LOCAL_FILE_CONTENTS !important }')
    file.close
    yield %(<link rel="stylesheet" href="#{file.path}">)
  ensure
    file&.unlink
  end

  test 'email html does not read stylesheets linked from the content' do
    with_local_stylesheet do |link|
      html = EmailHelper.html(content: "#{link}<p>hi</p>")
      refute_includes html, 'LOCAL_FILE_CONTENTS'
    end
  end

  # A reply to a comment email as Mailgun posts it, signed with key, from an address SPF passed
  def inbound_reply_params(account, body, key:, timestamp: Time.now.to_i.to_s)
    token = SecureRandom.hex(25)
    {
      'timestamp' => timestamp, 'token' => token, 'signature' => OpenSSL::HMAC.hexdigest('SHA256', key, "#{timestamp}#{token}"),
      'sender' => account.email, 'from' => "#{account.name} <#{account.email}>", 'body-plain' => body,
      'message-headers' => [['From', account.email], ['Subject', 'Re: Discussion'], ['X-Mailgun-Spf', 'Pass']].to_json
    }
  end

  def with_mailgun_signing_key(key, &)
    with_env({ 'MAILGUN_WEBHOOK_SIGNING_KEY' => key }, &)
  end

  test 'a reply to a comment email that Mailgun signed becomes a comment' do
    create_event
    discussion = @event.discussion_post!(@account)
    with_mailgun_signing_key('signing-key') do
      post "/inbound/#{discussion.id}", inbound_reply_params(@account, 'See you there', key: 'signing-key')
    end
    assert_equal 200, last_response.status
    assert_includes discussion.comments.order('created_at desc').first.body, 'See you there'
  end

  test 'an inbound email without Mailgun\'s signature is refused' do
    create_event
    discussion = @event.discussion_post!(@account)
    with_mailgun_signing_key('signing-key') do
      [
        inbound_reply_params(@account, 'Signed with another key', key: 'another-key'),
        inbound_reply_params(@account, 'Not signed', key: 'signing-key').except('signature'),
        inbound_reply_params(@account, 'Timestamp changed', key: 'signing-key').merge('timestamp' => '1')
      ].each do |params|
        post "/inbound/#{discussion.id}", params
        assert_equal 401, last_response.status, params['body-plain']
      end
    end
    with_mailgun_signing_key(nil) do
      post "/inbound/#{discussion.id}", inbound_reply_params(@account, 'No key set', key: '')
      assert_equal 401, last_response.status
    end
    assert_equal 0, discussion.comments.and(via_email: true).count
  end

  # A Mailgun click event for pmail, signed with key
  def mailgun_click_event(pmail, key:)
    timestamp = Time.now.to_i.to_s
    token = SecureRandom.hex(25)
    {
      'signature' => { 'timestamp' => timestamp, 'token' => token, 'signature' => OpenSSL::HMAC.hexdigest('SHA256', key, "#{timestamp}#{token}") },
      'event-data' => { 'event' => 'clicked', 'tags' => [pmail.id.to_s], 'url' => 'https://example.com/page' }
    }.to_json
  end

  test 'a click webhook signed with the organisation\'s key is counted' do
    covers 'organisations/mailgun-click-webhook@cc88d6'
    create_organisation(mailgun_webhook_signing_key: 'organisation-key')
    pmail = FactoryBot.create(:pmail, organisation: @organisation, recipient_kind: 'everyone')
    post "/o/#{@organisation.slug}/mailgun_webhook", mailgun_click_event(pmail, key: 'organisation-key'), 'CONTENT_TYPE' => 'application/json'
    assert_equal 200, last_response.status
    assert_equal 1, pmail.pmail_links.count
  end

  test 'a click webhook signed with Dandelion\'s key is refused' do
    covers 'organisations/mailgun-click-webhook@cc88d6'
    with_mailgun_signing_key('dandelion-key') do
      [nil, 'organisation-key'].each do |organisation_key|
        organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account), mailgun_webhook_signing_key: organisation_key)
        pmail = FactoryBot.create(:pmail, organisation: organisation, recipient_kind: 'everyone')
        post "/o/#{organisation.slug}/mailgun_webhook", mailgun_click_event(pmail, key: 'dandelion-key'), 'CONTENT_TYPE' => 'application/json'
        assert_equal 401, last_response.status
        assert_equal 0, pmail.pmail_links.count
      end
    end
  end

  test 'inbound email html does not read stylesheets linked from the message' do
    with_local_stylesheet do |link|
      mail = Mail.new do
        html_part do
          content_type 'text/html; charset=UTF-8'
          body "<html><head>#{link}</head><body><p>hi</p></body></html>"
        end
      end
      _mail, html, = EmailReceiver.allocate.receive(mail)
      refute_includes html, 'LOCAL_FILE_CONTENTS'
    end
  end

  test 'plain text email fields do not read linked stylesheets' do
    create_event
    options = nil
    new_premailer = Premailer.method(:new)
    Premailer.stub :new, lambda { |html, **opts|
      options = opts
      new_premailer.call(html, **opts)
    } do
      EmailFields.replace_magic_tags('<link rel="stylesheet" href="/dev/zero">Ticket to [event_name]', event: @event, plain_text: true)
    end
    assert_equal false, options[:include_link_tags]
  end
end
