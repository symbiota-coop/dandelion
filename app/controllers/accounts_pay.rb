Dandelion::App.controller do
  post '/accounts/stripe_webhook' do
    payload = request.body.read
    event = nil
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, ENV['STRIPE_ENDPOINT_SECRET_ACCOUNTS']
      )
    rescue JSON::ParserError
      halt 400
    rescue Stripe::SignatureVerificationError
      halt 200
    end

    if event['type'] == 'checkout.session.completed'
      session = event['data']['object']
      if (account_contribution = AccountContribution.find_by(session_id: session.id))
        account_contribution.set(payment_completed: true)
        account_contribution.send_notification
      end
    end
    halt 200
  end

  post '/accounts/coinbase_webhook' do
    payload = request.body.read
    sig_header = request.env['HTTP_X_CC_WEBHOOK_SIGNATURE']

    begin
      event = CoinbaseCommerce::Webhook.construct_event(payload, sig_header, ENV['COINBASE_WEBHOOK_SECRET'])
    rescue JSON::ParserError
      halt 400
    rescue CoinbaseCommerce::Errors::SignatureVerificationError
      halt 400
    rescue CoinbaseCommerce::Errors::WebhookInvalidPayload
      halt 400
    end

    if event.type == 'charge:confirmed' && event.data.respond_to?(:checkout) && (account_contribution = AccountContribution.find_by(coinbase_checkout_id: event.data.checkout.id))
      account_contribution.set(payment_completed: true)
    end
    halt 200
  end

  post '/accounts/:id/pay', provides: :json do
    @account = Account.find(params[:id])

    case params[:payment_method]
    when 'stripe'

      Stripe.api_key = ENV['STRIPE_SK']
      Stripe.api_version = '2020-08-27'
      stripe_session_hash = {
        line_items: [{
          name: 'Dandelion',
          description: 'Contribution to Dandelion',
          amount: (params[:amount].to_f * 100).round,
          currency: params[:currency],
          quantity: 1
        }],
        customer_email: @account.email,
        success_url: "#{ENV['BASE_URI']}/donate?thanks=true",
        cancel_url: (ENV['BASE_URI']).to_s
      }
      session = Stripe::Checkout::Session.create(stripe_session_hash)
      @account.account_contributions.create! amount: params[:amount].to_f, currency: params[:currency], session_id: session.id, payment_intent: session.payment_intent
      { session_id: session.id }.to_json

    when 'coinbase'

      client = CoinbaseCommerce::Client.new(api_key: ENV['COINBASE_API_KEY'])

      checkout = client.checkout.create(
        name: 'Dandelion',
        description: 'Contribution to Dandelion',
        pricing_type: 'fixed_price',
        local_price: {
          amount: params[:amount].to_f,
          currency: params[:currency]
        },
        requested_info: %w[email]
      )
      @account.account_contributions.create! amount: params[:amount].to_f, currency: params[:currency], coinbase_checkout_id: checkout.id
      { checkout_id: checkout.id }.to_json

    end
  end
end
