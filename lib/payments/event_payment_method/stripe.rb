class EventPaymentMethod
  module Stripe
    def self.call(order:, event:, account:, cohost: nil, utm: {}, **)
      cohost = cohost && Organisation.find_by(slug: cohost)
      event_image = event.image_source(cohost)&.image
      revenue_sharer_organisationship = event.revenue_sharer_organisationship
      tax_rate_id = event.tax_rate_id || event.organisation.tax_rate_id

      stripe_session_hash = {
        customer_email: account.email,
        success_url: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{event.slug}?success=true&order_id=#{order.public_id}&utm_source=#{utm[:source]}&utm_medium=#{utm[:medium]}&utm_campaign=#{utm[:campaign]}"),
        cancel_url: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{event.slug}?cancelled=true"),
        # Closes as the order's hold on its tickets ends, so no one pays for tickets the cleanup has released (Stripe's
        # default is 24 hours)
        expires_at: (order.created_at + Order::UNPAID_HOLD).to_i,
        metadata: order.metadata,
        billing_address_collection: event.organisation.billing_address_collection? ? 'required' : nil,
        line_items: line_items(order: order, event: event, event_image: event_image, tax_rate_id: tax_rate_id)
      }

      payment_intent_data = { description: order.description, metadata: order.metadata }
      application_fee_amount = nil
      if revenue_sharer_organisationship
        application_fee_amount = order.calculate_application_fee_amount
        if event.direct_charges
          payment_intent_data.merge!(application_fee_amount: (application_fee_amount * 100).round)
        else
          payment_intent_data.merge!(
            application_fee_amount: (application_fee_amount * 100).round,
            transfer_data: { destination: revenue_sharer_organisationship.stripe_user_id }
          )
        end
      elsif event.donations_to_dandelion?
        application_fee_amount = order.donation_revenue.cents.to_f / 100
        payment_intent_data.merge!(application_fee_amount: (application_fee_amount * 100).round)
      end
      stripe_session_hash.merge!(payment_intent_data: payment_intent_data)

      stripe_account = if revenue_sharer_organisationship && event.direct_charges
                         revenue_sharer_organisationship.stripe_user_id
                       elsif event.organisation.stripe_connect_json
                         event.organisation.stripe_user_id
                       end
      opts = StripeOpts.call(
        api_key: event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : event.organisation.stripe_sk,
        stripe_account: stripe_account
      )
      session = ::Stripe::Checkout::Session.create(stripe_session_hash, opts)

      order.update_attributes!(
        value: order.total.round(2),
        session_id: session.id,
        payment_intent: session.payment_intent,
        application_fee_amount: application_fee_amount
      )
      order.tickets.each do |ticket|
        ticket.update_attributes!(session_id: session.id, payment_intent: session.payment_intent)
      end

      { session_id: session.id, session_url: session.url }.to_json
    end

    def self.line_items(order:, event:, event_image:, tax_rate_id:)
      total_cents = (order.total * 100).round
      untaxed_donation_cents = if tax_rate_id
                                 [order.donation_revenue.cents, total_cents].min
                               else
                                 0
                               end
      ticket_cents = total_cents - untaxed_donation_cents

      items = []
      if ticket_cents.positive?
        items << {
          name: event.name,
          description: order.description(include_donations: !untaxed_donation_cents.positive?),
          images: [event_image.try(:url)].compact,
          amount: ticket_cents,
          currency: order.currency,
          quantity: 1,
          tax_rates: tax_rate_id ? [tax_rate_id] : nil
        }
      end

      if untaxed_donation_cents.positive?
        items << {
          name: order.application_fee_paid_to_dandelion? ? 'Donation to Dandelion' : "Donation to #{event.organisation.name}",
          amount: untaxed_donation_cents,
          currency: order.currency,
          quantity: 1
        }
      end

      items
    end

    def self.refund(record, on_error:, amount: nil, refund_application_fee: false, **)
      event = record.event
      opts = StripeOpts.call(
        api_key: event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : event.organisation.stripe_sk,
        stripe_account: event.organisation.stripe_user_id
      )
      pi = ::Stripe::PaymentIntent.retrieve(record.payment_intent, opts)
      charge = pi.charges.first

      # Some or all of the charge may have been refunded already, by refunding its order's tickets one by one or in
      # Stripe's dashboard, and Stripe refuses to refund more than is left. So refund only what's left, and nothing
      # (without an error) if that's nothing
      unrefunded_cents = charge.amount - charge.amount_refunded
      return if unrefunded_cents <= 0

      refund_cents = amount ? [(amount * 100).to_i, unrefunded_cents].min : unrefunded_cents
      params = { charge: charge.id }
      # With no amount, Stripe refunds the whole charge
      params[:amount] = refund_cents if amount || charge.amount_refunded.positive?

      if event.revenue_sharer_organisationship
        params.merge!(refund_application_fee: true, reverse_transfer: true)
        ::Stripe::Refund.create(params, opts.except(:stripe_account))
      else
        params[:refund_application_fee] = true if event.organisation.stripe_user_id && refund_application_fee
        ::Stripe::Refund.create(params, opts)
      end
      refund_rest_of_application_fee(charge, opts) if refund_application_fee && params[:amount] && refund_cents == unrefunded_cents

      # What was refunded, for the attendee's email, as it can be less than was asked for
      refund_cents / 100.0
    rescue ::Stripe::InvalidRequestError => e
      on_error.call(e) if on_error
      true
    end

    # A refund with an amount returns only its share of the application fee (fee × amount / charge), even when it
    # refunds the rest of a charge, so a fee that earlier refunds left with the platform (ticket refunds don't refund it,
    # nor need refunds in Stripe's dashboard) would stay there, and the connected account would fund the buyer's refund
    # of it. So once the charge is all refunded, refund whatever of the fee is left. The buyer's refund has gone
    # through, so a failure here is reported rather than emailed as a failed refund
    def self.refund_rest_of_application_fee(charge, opts)
      return unless charge.application_fee

      platform_opts = opts.except(:stripe_account)
      fee = ::Stripe::ApplicationFee.retrieve(charge.application_fee, platform_opts)
      left = fee.amount - fee.amount_refunded
      ::Stripe::ApplicationFee.create_refund(fee.id, { amount: left }, platform_opts) if left.positive?
    rescue ::Stripe::StripeError => e
      ErrorReporting.capture_exception(e, context: { charge: charge.id, application_fee: charge.application_fee })
    end
  end
end
