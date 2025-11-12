Dandelion::App.controller do
  post '/g/:slug/stripe_webhook' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, @gathering.stripe_endpoint_secret
      )
    rescue Stripe::SignatureVerificationError => e
      Honeybadger.notify(e)
      halt 200
    end

    if event['type'] == 'checkout.session.completed'
      session = event['data']['object']
      if (payment = @gathering.payments.find_by(session_id: session.id))
        begin
          payment.payment_completed!
        rescue StandardError => e
          Honeybadger.notify(e)
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
      event = CoinbaseCommerceClient::Webhook.construct_event(payload, sig_header, @gathering.coinbase_webhook_secret)
    rescue JSON::ParserError
      halt 400
    rescue CoinbaseCommerceClient::Errors::SignatureVerificationError
      halt 400
    rescue CoinbaseCommerceClient::Errors::WebhookInvalidPayload
      halt 400
    end

    if event.type == 'charge:confirmed' && event.data.respond_to?(:checkout) && (payment = @gathering.payments.find_by(coinbase_checkout_id: event.data.checkout.id))
      payment.payment_completed!
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
      @membership.payments.create! amount: params[:amount].to_i, currency: @gathering.currency, session_id: session.id, payment_intent: session.payment_intent, payment_completed: false
      { session_id: session.id }.to_json

    when 'coinbase'

      client = CoinbaseCommerceClient::Client.new(api_key: @gathering.coinbase_api_key)

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
      @membership.payments.create! amount: params[:amount].to_i, currency: @gathering.currency, coinbase_checkout_id: checkout.id, payment_completed: false
      { checkout_id: checkout.id }.to_json

    when 'evm'

      evm_secret = Array.new(4) { [*'1'..'9'].sample }.join
      payment = @membership.payments.create!(
        amount: params[:amount].to_i,
        currency: @gathering.currency,
        evm_secret: evm_secret,
        payment_completed: false
      )
      { evm_secret: payment.evm_secret, evm_amount: payment.evm_amount, evm_wei: (payment.evm_amount * 1e18.to_d).to_i, payment_id: payment.id.to_s, payment_expiry: (payment.created_at + 1.hour).to_datetime.strftime('%Q') }.to_json

    end
  end

  get '/g/:slug/payments/:payment_id', provides: :json do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!
    @payment = @gathering.payments.find(params[:payment_id])
    @gathering.check_evm_account if @payment.evm_secret && @gathering.evm_address
    { id: @payment.id.to_s, payment_completed: @payment.payment_completed || false }.to_json
  end
end
