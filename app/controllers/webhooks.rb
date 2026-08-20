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
      elsif event.resource_type == 'payments' && event.action == 'confirmed'
        payment_request_id = event.to_h.dig('links', 'payment_request')
        payment_id = event.links.payment
        next unless payment_request_id

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
      elsif event.resource_type == 'billing_requests' && event.action == 'fulfilled'
        billing_request_id = event.links.billing_request
        next unless billing_request_id

        @order = @organisation.orders.find_by(gocardless_billing_request_id: billing_request_id, payment_completed: false)
        @order ||= Order.deleted.find_by(gocardless_billing_request_id: billing_request_id, payment_completed: false)
        next unless @order

        client = GoCardlessPro::Client.new(access_token: @organisation.gocardless_access_token)
        billing_request = client.billing_requests.get(@order.gocardless_billing_request_id)
        mandate_id = billing_request.links.mandate_request_mandate if billing_request&.status == 'fulfilled'
        raise 'fulfilled billing request did not include a mandate' if mandate_id.blank?

        total_pence = (@order.value * 100).round
        count = @order.event.gocardless_instalment_count.to_i
        base = total_pence / count
        remainder = total_pence % count
        amounts = Array.new(count) { |i| i.zero? ? base + remainder : base }

        begin
          client.instalment_schedules.create_with_schedule(
            params: {
              name: @order.description.truncate(100),
              currency: @order.currency,
              total_amount: total_pence,
              instalments: {
                interval_unit: 'monthly',
                interval: 1,
                amounts: amounts
              },
              links: { mandate: mandate_id }
            },
            headers: { 'Idempotency-Key' => "dandelion-order-#{@order.id}-instalment-schedule" }
          )
        rescue GoCardlessPro::InvalidStateError => e
          raise unless e.try(:idempotent_creation_conflict?)
        end

        if @order.deleted?
          @order.restore_and_complete
        else
          @order.payment_completed!
          @order.send_tickets
          @order.create_order_notification
        end
      end
    end
    200
  end
end
