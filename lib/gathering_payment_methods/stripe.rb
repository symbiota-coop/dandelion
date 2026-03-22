class GatheringPaymentMethod
  module Stripe
    def self.call(gathering:, membership:, account:, params:)
      ::Stripe.api_key = gathering.stripe_sk
      ::Stripe.api_version = ENV['STRIPE_API_VERSION']
      stripe_session_hash = {
        line_items: [{
          name: 'Dandelion',
          description: "Payment for #{gathering.name}",
          images: [gathering.image.try(:url)].compact,
          amount: params[:amount].to_i * 100,
          currency: gathering.currency,
          quantity: 1
        }],
        customer_email: account.email,
        success_url: "#{ENV['BASE_URI']}/g/#{gathering.slug}",
        cancel_url: "#{ENV['BASE_URI']}/g/#{gathering.slug}",
        metadata: {
          de_gathering_id: gathering.id,
          de_account_id: membership.account.id
        }
      }
      session = ::Stripe::Checkout::Session.create(stripe_session_hash)
      membership.payments.create! amount: params[:amount].to_i, currency: gathering.currency, session_id: session.id, payment_intent: session.payment_intent
      { session_id: session.id }.to_json
    end
  end
end
