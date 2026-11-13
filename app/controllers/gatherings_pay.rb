Dandelion::App.controller do
  post '/g/:slug/stripe_webhook' do # rubocop:disable Dandelion/GatheringPermission -- Stripe calls it, and it checks the event's signature
    @gathering = gathering_from_params
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, @gathering.stripe_endpoint_secret
      )
    rescue Stripe::SignatureVerificationError => e
      ErrorReporting.capture_exception(e)
      halt 200
    end

    if (session = StripeCheckout.paid_session(event))
      if (payment = @gathering.payments.find_by(session_id: session.id, payment_completed: false))
        begin
          payment.payment_completed!
        rescue StandardError => e
          ErrorReporting.capture_exception(e)
          halt 200
        end
      end
    end
    halt 200
  end

  post '/g/:slug/pay', provides: :json do
    @gathering = gathering_from_params
    membership_required!

    pm = GatheringPaymentMethod.object(params[:payment_method].to_s)
    halt 400 unless pm&.process
    halt 400 unless pm.available?(@gathering)

    pm.process_payment(gathering: @gathering, membership: @membership, account: current_account, params: params)
  end

  get '/g/:slug/payments/:payment_id', provides: :json do
    @gathering = gathering_from_params
    membership_required!
    @payment = @gathering.payments.find(params[:payment_id]) || not_found
    own_or_gathering_admins_only!(@payment)
    if @payment.evm_secret && @gathering.evm_address
      @gathering.check_evm_account
      # It completes a copy of its own
      @payment.reload
    end
    { id: @payment.id.to_s, payment_completed: @payment.payment_completed || false }.to_json
  end
end
