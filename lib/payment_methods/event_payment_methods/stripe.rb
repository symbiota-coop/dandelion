class EventPaymentMethod
  module Stripe
    def self.call(order:, event:, account:, details_form:, ticket_form:)
      cohost = ticket_form[:cohost] && Organisation.find_by(slug: ticket_form[:cohost])
      event_image = event.image_source(cohost)&.image
      revenue_sharer_organisationship = event.revenue_sharer_organisationship
      tax_rate_id = event.tax_rate_id || event.organisation.tax_rate_id

      stripe_session_hash = {
        customer_email: account.email,
        success_url: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{event.slug}?success=true&order_id=#{order.id}&utm_source=#{details_form[:utm_source]}&utm_medium=#{details_form[:utm_medium]}&utm_campaign=#{details_form[:utm_campaign]}"),
        cancel_url: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{event.slug}?cancelled=true"),
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
  end
end
