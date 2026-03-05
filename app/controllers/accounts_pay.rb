Dandelion::App.controller do
  post '/accounts/stripe_webhook' do
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    event = Stripe::Webhook.construct_event(
      payload, sig_header, ENV['STRIPE_ENDPOINT_SECRET_ACCOUNTS']
    )

    case event['type']
    when 'checkout.session.completed'
      session = event['data']['object']
      if (account_contribution = AccountContribution.find_by(session_id: session.id))
        account_contribution.set(payment_completed: true)
        account_contribution.send_notification
      end
    when 'customer.subscription.created'
      subscription = event.data.object
      Stripe.api_key = ENV['STRIPE_SK']
      Stripe.api_version = ENV['STRIPE_API_VERSION']
      customer = Stripe::Customer.retrieve(subscription.customer)
      email = customer.email
      if (account = Account.find_by(email: email.downcase))
        account.set(stripe_subscription_id: subscription.id)
        account.send_stripe_subscription_created_notification(subscription)
      end
    when 'customer.subscription.deleted'
      subscription = event.data.object
      if (account = Account.find_by(stripe_subscription_id: subscription.id))
        account.set(stripe_subscription_id: nil)
        account.send_stripe_subscription_deleted_notification(subscription)
      end
    end

    halt 200
  end

  post '/accounts/:id/pay', provides: :json do
    @account = Account.find(params[:id])
    halt 400 unless params[:amount].to_f > 0

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
        customer_email: @account.email,
        success_url: "#{ENV['BASE_URI']}/donate?thanks=true",
        cancel_url: "#{ENV['BASE_URI']}/donate"
      }
      session = Stripe::Checkout::Session.create(stripe_session_hash)
      @account.account_contributions.create! source: params[:source], amount: params[:amount].to_f, currency: params[:currency], session_id: session.id, payment_intent: session.payment_intent
      { session_id: session.id }.to_json

    end
  end
end
