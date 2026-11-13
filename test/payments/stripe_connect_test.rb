require_relative '../test_config'
require_relative '../helpers/checkout_webhook_helpers'

# Stripe Connect: the webhook for checkouts on connected accounts, connecting an organisation's (or a person's) Stripe
# account by OAuth, and disconnecting it
class PaymentsStripeConnectTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include CheckoutWebhookHelpers

  CONNECT_SECRET = 'whsec_connect_test'.freeze

  # Webhook

  def checkout_completed_payload(session_id, type: 'checkout.session.completed', payment_status: 'paid')
    { id: "evt_#{SecureRandom.hex(4)}", object: 'event', type: type, data: { object: { id: session_id, object: 'checkout.session', payment_status: payment_status } } }.to_json
  end

  # Posts payload to the Connect webhook as Stripe would, signed with secret
  def deliver_connect_webhook(payload, secret: CONNECT_SECRET)
    timestamp = Time.now
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret)
    with_env({ 'STRIPE_ENDPOINT_SECRET_CONNECT' => CONNECT_SECRET }) do
      header 'Stripe-Signature', Stripe::Webhook::Signature.generate_header(timestamp, signature)
      header 'Content-Type', 'application/json'
      post '/organisations/stripe_connect_webhook', payload
    end
  end

  # The queued jobs that would email order's tickets, matched by the order's session id and the method each calls, as
  # the records a job carries can mention send_tickets too
  def send_tickets_jobs(order)
    Delayed::Job.all.select do |job|
      job.handler.match?(/^method_name: :send_tickets(_without_delay)?$/) && job.handler.include?("session_id: #{order.session_id}\n")
    end
  end

  def create_connect_order
    create_organisation(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json)
    create_event(prices: [10])
    create_incomplete_order(@event, value: 10, session_id: "cs_#{SecureRandom.hex(4)}")
  end

  test 'a paid checkout on a connected account completes its order and sends the tickets once' do
    order = create_connect_order

    deliver_connect_webhook(checkout_completed_payload(order.session_id))

    assert_equal 200, last_response.status
    assert order.reload.payment_completed?
    assert order.tickets.first.payment_completed?
    assert_equal 1, send_tickets_jobs(order).count
  end

  test 'a checkout that is not yet paid waits for its async payment to succeed' do
    order = create_connect_order

    deliver_connect_webhook(checkout_completed_payload(order.session_id, payment_status: 'unpaid'))
    assert_equal 200, last_response.status
    refute order.reload.payment_completed?
    assert_equal 0, send_tickets_jobs(order).count

    deliver_connect_webhook(checkout_completed_payload(order.session_id, type: 'checkout.session.async_payment_succeeded'))
    assert order.reload.payment_completed?
    assert_equal 1, send_tickets_jobs(order).count
  end

  test 'a paid checkout restores and completes its order once it was deleted' do
    order = create_connect_order
    order.destroy
    assert_nil Order.find(order.id)

    deliver_connect_webhook(checkout_completed_payload(order.session_id))

    assert_equal 200, last_response.status
    restored = Order.find(order.id)
    assert restored
    assert restored.payment_completed?
    assert restored.restored?
    assert_equal 1, restored.tickets.count
    assert restored.tickets.first.payment_completed?
    assert_equal 1, send_tickets_jobs(order).count
  end

  test 'the same webhook delivered again does not complete the order twice' do
    order = create_connect_order
    payload = checkout_completed_payload(order.session_id)

    deliver_connect_webhook(payload)
    completed_at = order.reload.completed_at
    deliver_connect_webhook(payload)

    assert_equal 200, last_response.status
    assert_equal completed_at, order.reload.completed_at
    assert_equal 1, order.tickets.count
    assert_equal 1, send_tickets_jobs(order).count
  end

  test 'an order already completed is left as it was' do
    order = create_connect_order
    order.payment_completed!
    completed_at = order.reload.completed_at

    deliver_connect_webhook(checkout_completed_payload(order.session_id))

    assert_equal 200, last_response.status
    assert_equal completed_at, order.reload.completed_at
    assert_equal 0, send_tickets_jobs(order).count
  end

  test 'a paid checkout with an unknown session id changes nothing' do
    covers_route 'POST /organisations/stripe_connect_webhook'
    order = create_connect_order

    deliver_connect_webhook(checkout_completed_payload('cs_unknown'))

    assert_equal 200, last_response.status
    refute order.reload.payment_completed?
    assert_equal 0, send_tickets_jobs(order).count
  end

  test 'a webhook with a bad signature is refused and completes nothing' do
    order = create_connect_order

    deliver_connect_webhook(checkout_completed_payload(order.session_id), secret: 'whsec_wrong')
    assert_equal 200, last_response.status

    refute order.reload.payment_completed?
    assert_equal 0, send_tickets_jobs(order).count
  end

  # Disconnecting

  def connect_json
    { 'stripe_user_id' => 'acct_connected' }.to_json
  end

  test 'an organisation admin disconnects the organisation from Stripe, forgetting its account' do
    covers_route 'POST /organisations/stripe_disconnect'
    create_organisation(stripe_connect_json: connect_json)
    @organisation.set(stripe_account_json: { 'id' => 'acct_connect' }.to_json)
    sign_in_with_rack(@account)

    post '/organisations/stripe_disconnect', organisation_id: @organisation.id

    assert_equal 302, last_response.status
    assert_equal "/o/#{@organisation.slug}/edit", URI(last_response.location).path
    assert_nil @organisation.reload.stripe_connect_json
    assert_nil @organisation.stripe_account_json
  end

  test 'someone who is not an admin of the organisation cannot disconnect it from Stripe' do
    create_organisation(stripe_connect_json: connect_json)
    member = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: member)
    sign_in_with_rack(member)

    post '/organisations/stripe_disconnect', organisation_id: @organisation.id

    assert_equal 302, last_response.status
    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    assert_equal connect_json, @organisation.reload.stripe_connect_json
  end

  test 'disconnecting an organisation that does not exist is not found' do
    create_organisation
    sign_in_with_rack(@account)

    post '/organisations/stripe_disconnect', organisation_id: BSON::ObjectId.new.to_s

    assert_equal 404, last_response.status
  end

  test 'a member disconnects their own Stripe account from an organisation and no one else\'s' do
    create_organisation
    member = FactoryBot.create(:account)
    own = @organisation.organisationships.create!(account: member, stripe_connect_json: connect_json,
                                                  stripe_account_json: { 'id' => 'acct_member' }.to_json)
    admins = @organisation.organisationships.find_by(account: @account)
    admins.set(stripe_connect_json: connect_json)
    sign_in_with_rack(member)

    post "/o/#{@organisation.slug}/stripe_disconnect"

    assert_equal 302, last_response.status
    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    assert_nil own.reload.stripe_connect_json
    assert_nil own.stripe_account_json
    assert_equal connect_json, admins.reload.stripe_connect_json
  end

  test 'someone with no organisationship has nothing to disconnect' do
    create_organisation
    @organisation.organisationships.find_by(account: @account).set(stripe_connect_json: connect_json)
    sign_in_with_rack(FactoryBot.create(:account))

    post "/o/#{@organisation.slug}/stripe_disconnect"

    assert_equal 404, last_response.status
    assert_equal connect_json, @organisation.organisationships.find_by(account: @account).stripe_connect_json
  end

  test 'disconnecting a personal Stripe account needs signing in' do
    covers_route 'POST /o/:slug/stripe_disconnect'
    create_organisation
    @organisation.organisationships.find_by(account: @account).set(stripe_connect_json: connect_json)

    post "/o/#{@organisation.slug}/stripe_disconnect"

    assert_equal 302, last_response.status
    assert_equal connect_json, @organisation.organisationships.find_by(account: @account).stripe_connect_json
  end

  # Connecting (the OAuth callback). An organisation admin's own state connecting the organisation, and another account's
  # state being refused, are tested in organisations/payments_test.rb

  def oauth_state(organisation, account, personal: false)
    prefix = personal ? 'stripe_connect_personal' : 'stripe_connect_org'
    TokenVerifier.generate("#{prefix}:#{organisation.id}:#{account.id}", expires_in: STRIPE_CONNECT_OAUTH_STATE_EXPIRES_IN, purpose: STRIPE_CONNECT_OAUTH_STATE_PURPOSE)
  end

  # Stripe's OAuth token endpoint answers with token_json, and the account it names with account_attributes, so no
  # request reaches Stripe. Returns the codes the block's requests traded
  def stub_stripe_oauth(token_json: { 'stripe_user_id' => 'acct_new' }.to_json, account_attributes: { 'id' => 'acct_new' }, &)
    codes = []
    connection = Object.new
    connection.define_singleton_method(:post) do |_url, params|
      codes << params[:code]
      Struct.new(:success?, :body).new(true, token_json)
    end
    Faraday.stub(:new, ->(*) { connection }) do
      Stripe::Account.stub(:retrieve, account_attributes, &)
    end
    codes
  end

  test 'a personal connection\'s state cannot connect the organisation' do
    create_organisation
    sign_in_with_rack(@account)

    codes = stub_stripe_oauth { get '/organisations/stripe_connect', state: oauth_state(@organisation, @account, personal: true), code: 'ac_code' }

    assert_equal '/', URI(last_response.location).path
    assert_empty codes
    assert_nil @organisation.reload.stripe_connect_json
  end

  test 'a valid state for someone who is not an admin does not connect the organisation' do
    create_organisation
    member = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: member)
    sign_in_with_rack(member)

    codes = stub_stripe_oauth { get '/organisations/stripe_connect', state: oauth_state(@organisation, member), code: 'ac_code' }

    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    assert_empty codes
    assert_nil @organisation.reload.stripe_connect_json
  end

  test 'a connection cancelled on Stripe changes nothing' do
    create_organisation
    sign_in_with_rack(@account)

    codes = stub_stripe_oauth do
      get '/organisations/stripe_connect', state: oauth_state(@organisation, @account), error: 'access_denied', error_description: 'The user denied your request'
    end

    assert_equal "/o/#{@organisation.slug}/edit", URI(last_response.location).path
    assert_empty codes
    assert_nil @organisation.reload.stripe_connect_json
  end

  test 'a member connects their own Stripe account to an organisation, not the organisation\'s' do
    covers_route 'GET /o/:slug/stripe_connect'
    create_organisation
    member = FactoryBot.create(:account)
    sign_in_with_rack(member)
    token_json = { 'stripe_user_id' => 'acct_member', 'access_token' => 'sk_member' }.to_json

    codes = stub_stripe_oauth(token_json: token_json, account_attributes: { 'id' => 'acct_member' }) do
      get "/o/#{@organisation.slug}/stripe_connect", state: oauth_state(@organisation, member, personal: true), code: 'ac_code'
    end

    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    assert_equal ['ac_code'], codes
    organisationship = member.organisationships.find_by(organisation: @organisation)
    assert_equal token_json, organisationship.stripe_connect_json
    assert_equal({ 'id' => 'acct_member' }, JSON.parse(organisationship.stripe_account_json))
    assert_nil @organisation.reload.stripe_connect_json
  end

  test 'a personal connection whose state names another organisation fails the security check' do
    create_organisation
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    member = FactoryBot.create(:account)
    sign_in_with_rack(member)

    codes = stub_stripe_oauth do
      get "/o/#{@organisation.slug}/stripe_connect", state: oauth_state(other_organisation, member, personal: true), code: 'ac_code'
    end

    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    assert_empty codes
    assert_nil member.organisationships.find_by(organisation: @organisation)
    assert_nil member.organisationships.find_by(organisation: other_organisation)
  end

  test 'an organisation\'s state cannot connect a personal Stripe account' do
    create_organisation
    sign_in_with_rack(@account)

    codes = stub_stripe_oauth { get "/o/#{@organisation.slug}/stripe_connect", state: oauth_state(@organisation, @account), code: 'ac_code' }

    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    assert_empty codes
    assert_nil @organisation.organisationships.find_by(account: @account).stripe_connect_json
  end
end
