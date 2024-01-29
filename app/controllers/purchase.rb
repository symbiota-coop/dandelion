Dandelion::App.controller do
  post '/events/:id/purchase', provides: :json do
    @event = Event.find(params[:id]) || not_found

    ticketForm = params[:ticketForm]
    detailsForm = params[:detailsForm]

    account_hash = { name: detailsForm[:account][:name], email: detailsForm[:account][:email], postcode: detailsForm[:account][:postcode], country: detailsForm[:account][:country] }
    @account = if (account = Account.find_by(email: detailsForm[:account][:email].downcase))
                 account
               else
                 Account.new(account_hash.merge(skip_confirmation_email: true))
               end
    if @account.persisted?
      @account.update_attributes!(account_hash.map do |k, v|
                                    [k, v] if v
                                  end.compact.to_h)
    else
      begin
        @account.save!
      rescue StandardError
        halt 400
      end
    end

    halt 400 if @event.organisation.banned_emails_a.include?(@account.email)

    begin
      @order = Order.create!(
        event: @event,
        account: @account,
        currency: (params[:detailsForm][:payment_method] == 'evm' && @event.currency == 'USD' ? 'BREAD' : @event.currency),
        organisation_revenue_share: @event.organisation_revenue_share,
        revenue_sharer: (@event.revenue_sharer_organisationship.account if @event.revenue_sharer_organisationship),
        cohost: ticketForm[:cohost],
        affiliate_type: ticketForm[:affiliate_type],
        affiliate_id: ticketForm[:affiliate_id],
        discount_code_id: ticketForm[:discount_code_id],
        opt_in_organisation: (detailsForm[:account][:opt_in_organisation] == '1' || (detailsForm[:account][:opt_in_organisation].is_a?(Array) && detailsForm[:account][:opt_in_organisation].include?('1'))),
        opt_in_facilitator: (detailsForm[:account][:opt_in_facilitator].is_a?(Array) && detailsForm[:account][:opt_in_facilitator].include?('1')),
        hear_about: detailsForm[:account][:hear_about],
        http_referrer: detailsForm[:account][:http_referrer],
        answers: (detailsForm[:answers].map { |i, x| [@event.questions_a[i.to_i], x] } if detailsForm[:answers])
      )

      ticketForm[:quantities].each do |ticket_type_id, quantity|
        ticket_type = @event.ticket_types.find(ticket_type_id) || not_found
        quantity.to_i.times do
          @order.tickets.create!(event: @event, account: @account, ticket_type: ticket_type)
        end
      end
      raise Order::NoTickets if @order.tickets.count == 0

      @order.donations.create!(event: @event, account: @account, amount: ticketForm[:donation_amount]) if ticketForm[:donation_amount].to_f > 0

      @order.apply_credit if current_account
      @order.update_attribute(:original_description, @order.description)
    rescue StandardError => e
      Airbrake.notify(e)
      @order.try(:destroy)
      halt 400
    end

    begin
      if @order.total > 0

        case params[:detailsForm][:payment_method]
        when 'stripe'

          Stripe.api_key = @event.organisation.stripe_sk
          Stripe.api_version = '2020-08-27'

          if ticketForm[:cohost] && (cohost = Organisation.find_by(slug: ticketForm[:cohost])) && (cohostship = @event.cohostships.find_by(organisation: cohost)) && cohostship.image
            @event_image = cohostship.image.thumb('1920x1920')
          elsif @event.image
            @event_image = @event.image.thumb('1920x1920')
          end

          stripe_session_hash = {
            customer_email: @account.email,
            success_url: "#{ENV['BASE_URI']}/e/#{@event.slug}?success=true&order_id=#{@order.id}&utm_source=#{params[:detailsForm][:utm_source]}&utm_medium=#{params[:detailsForm][:utm_medium]}&utm_campaign=#{params[:detailsForm][:utm_campaign]}",
            cancel_url: "#{ENV['BASE_URI']}/e/#{@event.slug}?cancelled=true",
            metadata: @order.metadata,
            line_items: [{
              name: @event.name,
              description: @order.description,
              images: [@event_image.try(:url)].compact,
              amount: (@order.total * 100).round,
              currency: @order.currency,
              quantity: 1
            }]
          }
          payment_intent_data = {
            description: @order.description,
            metadata: @order.metadata
          }
          if (organisationship = @event.revenue_sharer_organisationship)
            application_fee_amount = @order.calculate_application_fee_amount
            payment_intent_data.merge!({
                                         application_fee_amount: (application_fee_amount * 100).round,
                                         transfer_data: {
                                           destination: organisationship.stripe_user_id
                                         }
                                       })
          end
          stripe_session_hash.merge!({
                                       payment_intent_data: payment_intent_data
                                     })
          session = Stripe::Checkout::Session.create(stripe_session_hash)
          @order.update_attributes!(
            value: @order.total.round(2),
            session_id: session.id,
            payment_intent: session.payment_intent,
            application_fee_amount: (application_fee_amount if organisationship)
          )
          @order.tickets.each do |ticket|
            ticket.update_attributes!(
              session_id: session.id,
              payment_intent: session.payment_intent
            )
          end

          { session_id: session.id }.to_json

        when 'coinbase'

          client = CoinbaseCommerce::Client.new(api_key: @event.organisation.coinbase_api_key)

          checkout = client.checkout.create(
            name: @event.name,
            description: @order.description.truncate(200),
            pricing_type: 'fixed_price',
            local_price: {
              amount: @order.total,
              currency: @order.currency
            },
            requested_info: %w[email]
          )
          @order.update_attributes!(
            value: @order.total.round(2),
            coinbase_checkout_id: checkout.id
          )
          { checkout_id: checkout.id }.to_json

        when 'seeds'

          seeds_secret = Array.new(5) { [*'a'..'z', *'0'..'9'].sample }.join
          @order.update_attributes!(
            value: @order.total.round(2),
            seeds_secret: seeds_secret
          )
          { seeds_secret: @order.seeds_secret, seeds_value: @order.seeds_value, order_id: @order.id.to_s, order_expiry: (@order.created_at + 1.hour).to_datetime.strftime('%Q') }.to_json

        when 'opencollective'

          oc_secret = "dandelion:#{Array.new(5) { [*'a'..'z', *'0'..'9'].sample }.join}"
          @order.update_attributes!(
            value: @order.total.round(2),
            oc_secret: oc_secret
          )
          { oc_secret: @order.oc_secret, currency: @order.currency, value: @order.value, order_id: @order.id.to_s, order_expiry: (@order.created_at + 1.hour).to_datetime.strftime('%Q') }.to_json

        when 'evm'

          evm_secret = Array.new(6) { [*'1'..'9'].sample }.join
          @order.update_attributes!(
            value: @order.total.round(2),
            evm_secret: evm_secret
          )
          { evm_secret: @order.evm_secret, evm_value: @order.evm_value, evm_wei: (@order.evm_value * 1e18.to_d).to_i, order_id: @order.id.to_s, order_expiry: (@order.created_at + 1.hour).to_datetime.strftime('%Q') }.to_json

        else
          raise Order::PaymentMethodNotFound
        end
      else
        @order.payment_completed!
        @order.send_tickets
        @order.create_order_notification
        { order_id: @order.id.to_s }.to_json
      end
    rescue StandardError => e
      Airbrake.notify(e,
                      url: "#{ENV['BASE_URI']}#{request.path}",
                      current_account: (JSON.parse(current_account.to_json) if current_account),
                      params: params,
                      request: request.env.select { |_k, v| v.is_a?(String) },
                      session: session,
                      order: @order)
      @order.destroy
      halt 400
    end
  end
end
