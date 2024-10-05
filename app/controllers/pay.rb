Dandelion::App.controller do
  post '/g/:slug/stripe_webhook' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    payload = request.body.read
    event = nil
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    event = Stripe::Webhook.construct_event(
      payload, sig_header, @gathering.stripe_endpoint_secret
    )

    if event['type'] == 'checkout.session.completed'
      session = event['data']['object']
      if (payment_attempt = @gathering.payment_attempts.find_by(session_id: session.id))
        begin
          Payment.create!(payment_attempt: payment_attempt)
        rescue StandardError => e
          airbrake_notify(e)
          halt 200
        end
      end
    end
    halt 200
  end

  post '/g/:slug/coinbase_webhook' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    payload = request.body.read
    sig_header = request.env['HTTP_X_CC_WEBHOOK_SIGNATURE']

    begin
      event = CoinbaseCommerce::Webhook.construct_event(payload, sig_header, @gathering.coinbase_webhook_secret)
    rescue JSON::ParserError
      halt 400
    rescue CoinbaseCommerce::Errors::SignatureVerificationError
      halt 400
    rescue CoinbaseCommerce::Errors::WebhookInvalidPayload
      halt 400
    end

    if event.type == 'charge:confirmed' && event.data.respond_to?(:checkout) && (payment_attempt = @gathering.payment_attempts.find_by(coinbase_checkout_id: event.data.checkout.id))
      Payment.create!(payment_attempt: payment_attempt)
    end
    halt 200
  end

  post '/g/:slug/pay', provides: :json do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!

    case params[:payment_method]
    when 'stripe'

      Stripe.api_key = @gathering.stripe_sk
      Stripe.api_version = '2020-08-27'
      stripe_session_hash = {
        line_items: [{
          name: 'Dandelion',
          description: "Payment for #{@gathering.name}",
          images: [@gathering.image.try(:url)].compact,
          amount: params[:amount].to_i * 100,
          currency: @gathering.currency,
          quantity: 1
        }],
        customer_email: current_account.email,
        success_url: "#{ENV['BASE_URI']}/g/#{@gathering.slug}",
        cancel_url: "#{ENV['BASE_URI']}/g/#{@gathering.slug}",
        metadata: {
          de_gathering_id: @gathering.id,
          de_account_id: @membership.account.id
        }
      }
      session = Stripe::Checkout::Session.create(stripe_session_hash)
      @membership.payment_attempts.create! amount: params[:amount].to_i, currency: @gathering.currency, session_id: session.id, payment_intent: session.payment_intent
      { session_id: session.id }.to_json

    when 'coinbase'

      client = CoinbaseCommerce::Client.new(api_key: @gathering.coinbase_api_key)

      checkout = client.checkout.create(
        name: 'Dandelion',
        description: "Payment for #{@gathering.name}",
        pricing_type: 'fixed_price',
        local_price: {
          amount: params[:amount].to_i,
          currency: @gathering.currency
        },
        requested_info: %w[email]
      )
      @membership.payment_attempts.create! amount: params[:amount].to_i, currency: @gathering.currency, coinbase_checkout_id: checkout.id
      { checkout_id: checkout.id }.to_json

    when 'evm'

      evm_secret = Array.new(4) { [*'1'..'9'].sample }.join
      payment_attempt = @membership.payment_attempts.create!(
        amount: params[:amount].to_i,
        currency: @gathering.currency,
        evm_secret: evm_secret
      )
      { evm_secret: payment_attempt.evm_secret, evm_amount: payment_attempt.evm_amount, evm_wei: (payment_attempt.evm_amount * 1e18.to_d).to_i, payment_attempt_id: payment_attempt.id.to_s, payment_attempt_expiry: (payment_attempt.created_at + 1.hour).to_datetime.strftime('%Q') }.to_json

    end
  end

  get '/g/:slug/payment_attempts/:payment_attempt_id', provides: :json do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!
    @payment_attempt = @gathering.payment_attempts.find(params[:payment_attempt_id])
    @gathering.check_evm_account if @payment_attempt.evm_secret && @gathering.evm_address
    { id: @payment_attempt.id.to_s, payment_completed: @gathering.payments.find_by(payment_attempt: @payment_attempt) ? true : false }.to_json
  end
end
