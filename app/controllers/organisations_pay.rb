Dandelion::App.controller do
  get '/o/:slug/contribute' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/contribute'
  end

  post '/organisations/stripe_webhook' do
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    event = Stripe::Webhook.construct_event(
      payload, sig_header, ENV['STRIPE_ENDPOINT_SECRET_ORGANISATIONS']
    )

    if event['type'] == 'checkout.session.completed'
      session = event['data']['object']
      if (organisation_contribution = OrganisationContribution.find_by(session_id: session.id))
        organisation_contribution.payment_completed = true
        organisation_contribution.save
        organisation_contribution.send_notification
      end
    end
    halt 200
  end

  post '/organisations/coinbase_webhook' do
    payload = request.body.read
    sig_header = request.env['HTTP_X_CC_WEBHOOK_SIGNATURE']

    begin
      event = Coinbase::Webhook.construct_event(payload, sig_header, ENV['COINBASE_WEBHOOK_SECRET'])
    rescue JSON::ParserError
      halt 400
    rescue Coinbase::Webhook::SignatureVerificationError
      halt 400
    end

    if event.type == 'charge:confirmed' && event.data.respond_to?(:checkout) && (organisation_contribution = OrganisationContribution.find_by(coinbase_checkout_id: event.data.checkout.id))
      organisation_contribution.payment_completed = true
      organisation_contribution.save
      organisation_contribution.send_notification
    end
    halt 200
  end

  post '/organisations/:id/stripe_setup', provides: :json do
    @organisation = Organisation.find(params[:id])

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = '2020-08-27'

    session = Stripe::Checkout::Session.create({
                                                 mode: 'setup',
                                                 currency: @organisation.currency,
                                                 customer_creation: 'always',
                                                 success_url: "#{ENV['BASE_URI']}/organisations/#{@organisation.id}/stripe_setup_complete?session_id={CHECKOUT_SESSION_ID}",
                                                 cancel_url: "#{ENV['BASE_URI']}/events/new?organisation_id=#{@organisation.id}"
                                               })

    { session_id: session.id }.to_json
  end

  get '/organisations/:id/stripe_setup_complete' do
    @organisation = Organisation.find(params[:id])

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = '2020-08-27'

    session = Stripe::Checkout::Session.retrieve(params[:session_id])
    setup_intent = Stripe::SetupIntent.retrieve(session.setup_intent)
    payment_method = Stripe::PaymentMethod.retrieve(setup_intent.payment_method)

    if payment_method.respond_to?(:card)
      @organisation.set(stripe_customer_id: session.customer)
      @organisation.set(card_last4: payment_method.card.last4)
      @organisation.stripe_topup
      @organisation.update_paid_up_without_delay
    end

    redirect "/o/#{@organisation.slug}/contribute"
  end

  get '/organisations/:id/clear_stripe_customer_id' do
    @organisation = Organisation.find(params[:id])

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = '2020-08-27'

    @organisation.set(stripe_customer_id: nil)
    redirect "/o/#{@organisation.slug}/contribute"
  end

  post '/organisations/:id/pay', provides: :json do
    @organisation = Organisation.find(params[:id])
    halt 400 unless params[:amount] && params[:amount].to_f > 0

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
        customer_email: current_account.email,
        success_url: "#{ENV['BASE_URI']}/events/new?organisation_id=#{@organisation.id}",
        cancel_url: "#{ENV['BASE_URI']}/events/new?organisation_id=#{@organisation.id}"
      }
      session = Stripe::Checkout::Session.create(stripe_session_hash)
      @organisation.organisation_contributions.create! amount: params[:amount].to_f, currency: params[:currency], session_id: session.id, payment_intent: session.payment_intent
      { session_id: session.id }.to_json

    when 'coinbase'

      client = Coinbase::Client.new(ENV['COINBASE_API_KEY'])

      charge = client.create_charge(
        name: 'Dandelion',
        description: 'Contribution to Dandelion',
        pricing_type: 'fixed_price',
        local_price: {
          amount: params[:amount].to_f,
          currency: params[:currency]
        },
        requested_info: %w[email]
      )
      @organisation.organisation_contributions.create! amount: params[:amount].to_f, currency: params[:currency], coinbase_checkout_id: charge['data']['checkout']['id']
      { checkout_id: charge['data']['checkout']['id'] }.to_json

    end
  end
end
