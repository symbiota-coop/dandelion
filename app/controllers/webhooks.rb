Dandelion::App.controller do
  post '/o/:slug/stripe_webhook' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    halt 200 if @organisation.stripe_connect_json

    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, @organisation.stripe_endpoint_secret
      )
    rescue Stripe::SignatureVerificationError => e
      ErrorReporting.capture_exception(e)
      halt 200
    end

    if event['type'] == 'checkout.session.completed'
      session = event['data']['object']
      if (@order = @organisation.orders.find_by(session_id: session.id, payment_completed: false))
        @order.payment_completed!
        @order.update_destination_payment
        @order.send_tickets
        @order.create_order_notification
        halt 200
      elsif (@order = @organisation.orders.deleted.find_by(session_id: session.id, payment_completed: false))
        begin
          @order.restore_and_complete
          # raise Order::Restored
        rescue StandardError => e
          ErrorReporting.capture_exception(e, context: { stripe_event_id: event.id })
          halt 200
        end
      else
        halt 200
      end
    else
      halt 200
    end
  end

  post '/o/:slug/gocardless_webhook' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    webhook_endpoint_secret = @organisation.gocardless_endpoint_secret
    halt 200 unless webhook_endpoint_secret

    request_body = request.body.read
    signature_header = request.env['HTTP_WEBHOOK_SIGNATURE']
    events = GoCardlessPro::Webhook.parse(request_body: request_body, signature_header: signature_header, webhook_endpoint_secret: webhook_endpoint_secret)

    events.each do |event|
      if event.resource_type == 'subscriptions' && event.action == 'created'
        @organisation.gocardless_subscribe(subscription_id: event.links.subscription)
      elsif event.resource_type == 'billing_requests' && event.action == 'fulfilled'
        billing_request_id = event.links.billing_request
        next unless billing_request_id

        order = @organisation.orders.find_by(gocardless_billing_request_id: billing_request_id, payment_completed: false)
        order&.create_gocardless_instalment_schedule!
      elsif event.resource_type == 'instalment_schedules' && event.action == 'completed'
        schedule_id = event.links.instalment_schedule
        next unless schedule_id

        if (order = @organisation.orders.find_by(gocardless_instalment_schedule_id: schedule_id, payment_completed: false))
          order.complete_gocardless_instalments!
        elsif (order = Order.deleted.find_by(gocardless_instalment_schedule_id: schedule_id, payment_completed: false))
          begin
            order.tickets.deleted.each(&:restore)
            order.donations.deleted.each(&:restore)
            order.restore
            order.set(restored: true)
            order.complete_gocardless_instalments!
          rescue StandardError => e
            ErrorReporting.capture_exception(e, context: { gocardless_event_id: event.id })
          end
        end
      elsif event.resource_type == 'payments' && event.action == 'confirmed'
        payment_request_id = event.to_h.dig('links', 'payment_request')
        payment_id = event.links.payment
        instalment_schedule_id = event.links.instalment_schedule

        if instalment_schedule_id && (order = @organisation.orders.find_by(gocardless_instalment_schedule_id: instalment_schedule_id, payment_completed: false))
          amount_major = begin
            client = GoCardlessPro::Client.new(access_token: @organisation.gocardless_access_token)
            client.payments.get(payment_id).amount.to_i / 100.0
          rescue StandardError
            0
          end
          order.record_gocardless_instalment_payment!(payment_id: payment_id, amount_major: amount_major)
        elsif payment_request_id
          if (@order = @organisation.orders.find_by(gocardless_payment_request_id: payment_request_id, payment_completed: false))
            @order.persist_gocardless_payment_id(payment_id)
            @order.payment_completed!
            @order.send_tickets
            @order.create_order_notification
          elsif (@order = Order.deleted.find_by(gocardless_payment_request_id: payment_request_id, payment_completed: false))
            begin
              @order.persist_gocardless_payment_id(payment_id)
              @order.restore_and_complete
            rescue StandardError => e
              ErrorReporting.capture_exception(e, context: { gocardless_event_id: event.id })
            end
          end
        end
      end
    end
    200
  end
end
