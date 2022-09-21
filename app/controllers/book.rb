Dandelion::App.controller do
  post '/services/:id/book', provides: :json do
    @service = Service.find(params[:id]) || not_found
    halt 400 unless @service.organisationship

    bookingForm = params[:bookingForm]
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
      @account.save!
    end

    begin
      @booking = Booking.create!(
        start_time: bookingForm[:booking][:start_time],
        end_time: bookingForm[:booking][:end_time],
        service: @service,
        account: @account,
        value: @service.price,
        currency: @service.currency,
        opt_in_organisation: (detailsForm[:account][:opt_in_organisation] == '1' || (detailsForm[:account][:opt_in_organisation].is_a?(Array) && detailsForm[:account][:opt_in_organisation].include?('1'))),
        opt_in_facilitator: (detailsForm[:account][:opt_in_facilitator].is_a?(Array) && detailsForm[:account][:opt_in_facilitator].include?('1')),
        client_note: detailsForm[:account][:client_note]
      )
    rescue StandardError
      @booking.try(:destroy)
      halt 400
    end

    begin
      if @booking.value > 0

        case params[:detailsForm][:payment_method]
        when 'stripe'

          Stripe.api_key = @service.organisation.stripe_sk
          Stripe.api_version = '2020-08-27'

          stripe_session_hash = {
            payment_method_types: ['card'],
            customer_email: @account.email,
            success_url: "#{ENV['BASE_URI']}/services/#{@service.id}?success=true&booking_id=#{@booking.id}&utm_source=#{params[:detailsForm][:utm_source]}&utm_medium=#{params[:detailsForm][:utm_medium]}&utm_campaign=#{params[:detailsForm][:utm_campaign]}",
            cancel_url: "#{ENV['BASE_URI']}/services/#{@service.id}?cancelled=true",
            metadata: @booking.metadata,
            line_items: [{
              name: @service.name_with_provider,
              description: @booking.description,
              amount: (@booking.value * 100).round,
              currency: @booking.currency,
              quantity: 1
            }]
          }
          application_fee_amount = ((@booking.value * 100 * @service.organisation_revenue_share)).to_f / 100
          payment_intent_data = {
            description: @booking.description,
            metadata: @booking.metadata,
            application_fee_amount: (application_fee_amount * 100).round,
            transfer_data: {
              destination: @service.organisationship.stripe_user_id
            }
          }
          stripe_session_hash.merge!({
                                       payment_intent_data: payment_intent_data
                                     })
          session = Stripe::Checkout::Session.create(stripe_session_hash)
          @booking.update_attributes!(
            session_id: session.id,
            payment_intent: session.payment_intent,
            application_fee_amount: application_fee_amount,
            service_provider: @service.organisationship.account
          )
          { session_id: session.id }.to_json

        else
          if current_account && @service.account == current_account
            @booking.set(value: nil)
            @booking.set(currency: nil)
            @booking.send_confirmation_email
            { booking_id: @booking.id.to_s }.to_json
          else
            raise Booking::PaymentMethodNotFound
          end
        end
      else
        @booking.send_confirmation_email
        { booking_id: @booking.id.to_s }.to_json
      end
    rescue StandardError => e
      @booking.destroy
      raise e
    end
  end
end
