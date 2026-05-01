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
      if (organisation_contribution = OrganisationContribution.find_by(session_id: session.id, payment_completed: false))
        organisation_contribution.payment_completed = true
        organisation_contribution.save
        organisation_contribution.send_notification
      end
    end
    halt 200
  end

  post '/organisations/:id/stripe_setup', provides: :json do
    @organisation = Organisation.find(params[:id])
    organisation_admins_only!

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = ENV['STRIPE_API_VERSION']

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
    organisation_admins_only!

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = ENV['STRIPE_API_VERSION']

    session = Stripe::Checkout::Session.retrieve(params[:session_id])
    setup_intent = Stripe::SetupIntent.retrieve(session.setup_intent)
    payment_method = Stripe::PaymentMethod.retrieve(setup_intent.payment_method)

    begin
      @organisation.set(card_last4: payment_method.card&.last4)
      @organisation.set(stripe_customer_id: session.customer)
      @organisation.stripe_topup
      @organisation.update_paid_up_without_delay
    rescue StandardError => e
      ErrorReporting.capture_exception(e, context: { payment_method_id: payment_method&.id })
    end

    redirect "/o/#{@organisation.slug}/contribute"
  end

  get '/organisations/:id/clear_stripe_customer_id' do
    @organisation = Organisation.find(params[:id])
    organisation_admins_only!

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = ENV['STRIPE_API_VERSION']

    @organisation.set(stripe_customer_id: nil)
    redirect "/o/#{@organisation.slug}/contribute"
  end

  post '/organisations/:id/pay', provides: :json do
    @organisation = Organisation.find(params[:id])
    organisation_admins_only!

    halt 400 unless params[:amount] && params[:amount].to_f > 0

    case params[:payment_method]
    when 'stripe'

      Stripe.api_key = ENV['STRIPE_SK']
      Stripe.api_version = ENV['STRIPE_API_VERSION']
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

    end
  end
end
