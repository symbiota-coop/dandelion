Dandelion::App.controller do
  get '/organisations/stripe_connect' do
    @organisation = Organisation.find(params[:state]) || not_found
    organisation_admins_only!
    begin
      response = Mechanize.new.post 'https://connect.stripe.com/oauth/token', client_secret: ENV['STRIPE_SK'], code: params[:code], grant_type: 'authorization_code'
      @organisation.set(stripe_connect_json: response.body)
      Stripe.api_key = ENV['STRIPE_SK']
      Stripe.api_version = '2020-08-27'
      @organisation.set(stripe_account_json: Stripe::Account.retrieve(@organisation.stripe_user_id).to_json)
      flash[:notice] = 'Connected!'
    rescue StandardError
      flash[:error] = 'There was an error connecting your organisation'
    end
    redirect "/o/#{@organisation.slug}/edit?tab=payments"
  end

  get '/organisations/stripe_disconnect' do
    @organisation = Organisation.find(params[:organisation_id]) || not_found
    organisation_admins_only!
    @organisation.set(stripe_connect_json: nil)
    redirect "/o/#{@organisation.slug}/edit?tab=payments"
  end

  get '/o/:slug/stripe_connect' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
    begin
      response = Mechanize.new.post 'https://connect.stripe.com/oauth/token', client_secret: @organisation.stripe_sk, code: params[:code], grant_type: 'authorization_code'
      @organisationship.set(stripe_connect_json: response.body)
      Stripe.api_key = @organisation.stripe_sk
      Stripe.api_version = '2020-08-27'
      @organisationship.set(stripe_account_json: Stripe::Account.retrieve(@organisationship.stripe_user_id).to_json)
      flash[:notice] = "Connected to #{@organisation.name}!"
    rescue StandardError
      flash[:error] = 'There was an error connecting your account'
    end
    redirect "/o/#{@organisation.slug}"
  end

  get '/o/:slug/stripe_disconnect' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = current_account.organisationships.find_by(organisation: @organisation) || not_found
    @organisationship.set(stripe_connect_json: nil)
    redirect "/o/#{@organisation.slug}"
  end

  post '/organisations/stripe_connect_webhook' do
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    event = Stripe::Webhook.construct_event(
      payload, sig_header, ENV['STRIPE_ENDPOINT_SECRET_CONNECT']
    )

    if event['type'] == 'checkout.session.completed'
      session = event['data']['object']
      if (@order = Order.find_by(session_id: session.id, payment_completed: false))
        @order.payment_completed!
        @order.update_destination_payment
        @order.send_tickets
        @order.create_order_notification
        halt 200
      elsif (@order = Order.deleted.find_by(session_id: session.id, payment_completed: false))
        begin
          @order.restore_and_complete
          # raise Order::Restored
        rescue StandardError => e
          Honeybadger.context({ event_id: event.id })
          Honeybadger.notify(e)
          halt 200
        end
      else
        halt 200
      end
    else
      halt 200
    end
  end
end
