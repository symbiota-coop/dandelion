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
      Honeybadger.notify(e)
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

  post '/o/:slug/coinbase_webhook' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    payload = request.body.read
    sig_header = request.env['HTTP_X_CC_WEBHOOK_SIGNATURE']

    begin
      event = CoinbaseCommerceClient::Webhook.construct_event(payload, sig_header, @organisation.coinbase_webhook_secret)
    rescue JSON::ParserError
      halt 400
    rescue CoinbaseCommerceClient::Errors::SignatureVerificationError
      halt 400
    rescue CoinbaseCommerceClient::Errors::WebhookInvalidPayload
      halt 400
    end

    if event.type == 'charge:confirmed' && event.data.respond_to?(:checkout)
      if (@order = @organisation.orders.find_by(coinbase_checkout_id: event.data.checkout.id))
        @order.payment_completed!
        @order.send_tickets
        @order.create_order_notification
        halt 200
      elsif (@order = Order.deleted.find_by(coinbase_checkout_id: event.data.checkout.id))
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

  post '/o/:slug/gocardless_webhook' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    webhook_endpoint_secret = @organisation.gocardless_endpoint_secret
    request_body = request.body.tap(&:rewind).read
    signature_header = request.env['HTTP_WEBHOOK_SIGNATURE']
    events = GoCardlessPro::Webhook.parse(request_body: request_body, signature_header: signature_header, webhook_endpoint_secret: webhook_endpoint_secret)

    events.each do |event|
      if event.resource_type == 'subscriptions' && event.action == 'created'
        @organisation.gocardless_subscribe(subscription_id: event.links.subscription)
      elsif event.resource_type == 'billing_requests' && event.action == 'fulfilled'
        billing_request_id = event.links.billing_request

        if (@order = @organisation.orders.find_by(gocardless_billing_request_id: billing_request_id))
          @order.payment_completed!
          @order.send_tickets
          @order.create_order_notification
          halt 200
        elsif (@order = Order.deleted.find_by(gocardless_billing_request_id: billing_request_id))
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

      end
    end
    200
  end
end
