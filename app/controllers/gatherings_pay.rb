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
      ErrorTracking.notify(e)
      halt 200
    end

    if event['type'] == 'checkout.session.completed'
      session = event['data']['object']
      if (payment = @gathering.payments.find_by(session_id: session.id, payment_completed: false))
        begin
          payment.payment_completed!
        rescue StandardError => e
          ErrorTracking.notify(e)
          halt 200
        end
      end
    end
    halt 200
  end

  post '/g/:slug/pay', provides: :json do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!

    pm = GatheringPaymentMethod.object(params[:payment_method].to_s)
    halt 400 unless pm&.process
    halt 400 unless pm.available?(@gathering)

    pm.process_payment(gathering: @gathering, membership: @membership, account: current_account, params: params)
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
