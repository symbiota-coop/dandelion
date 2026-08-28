module StripeWebhooks
  extend ActiveSupport::Concern

  included do
    after_save :create_stripe_webhook_if_necessary, if: :stripe_sk
  end

  def stripe_webhooks
    opts = StripeOpts.call(api_key: stripe_sk)
    webhooks = []
    has_more = true
    starting_after = nil
    while has_more
      w = Stripe::WebhookEndpoint.list({ limit: 100, starting_after: starting_after }, opts)
      webhooks += w.data
      has_more = w.has_more
      starting_after = w.data.last.try(:id)
    end
    webhooks
  end

  def delete_stripe_webhook
    opts = StripeOpts.call(api_key: stripe_sk)
    webhook = stripe_webhooks.find { |w| w['url'] == stripe_webhook_url }
    Stripe::WebhookEndpoint.delete(webhook.id, {}, opts) if webhook
  end

  def create_stripe_webhook_if_necessary
    return unless Padrino.env == :production

    opts = StripeOpts.call(api_key: stripe_sk)

    return if stripe_webhooks.find { |w| w['url'] == stripe_webhook_url }

    w = Stripe::WebhookEndpoint.create({
                                         url: stripe_webhook_url,
                                         enabled_events: [
                                           'checkout.session.completed'
                                         ]
                                       }, opts)
    set(stripe_endpoint_secret: w['secret'])
  rescue Stripe::AuthenticationError
    set(stripe_sk: nil)
    set(stripe_pk: nil)
  end
end
