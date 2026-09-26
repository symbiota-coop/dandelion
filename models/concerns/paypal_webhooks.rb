module PaypalWebhooks
  extend ActiveSupport::Concern

  included do
    after_save :create_paypal_webhook_if_necessary, if: -> { paypal_client_id && paypal_secret }
  end

  def paypal_webhook_url
    "#{ENV['BASE_URI']}/o/#{slug}/paypal_webhook"
  end

  def create_paypal_webhook_if_necessary
    return unless Padrino.env == :production

    client = Paypal.new(
      client_id: paypal_client_id,
      secret: paypal_secret,
      sandbox: paypal_sandbox?
    )
    webhooks = client.list_webhooks['webhooks'] || []
    existing = webhooks.find { |w| w['url'] == paypal_webhook_url }

    if existing
      existing_names = (existing['event_types'] || []).map { |e| e['name'] }
      missing = Paypal::WEBHOOK_EVENT_TYPES - existing_names
      client.update_webhook_event_types(existing['id'], existing_names | Paypal::WEBHOOK_EVENT_TYPES) if missing.any?
      return
    end

    client.create_webhook(url: paypal_webhook_url)
  rescue Paypal::RequestError => e
    if e.status.to_i == 401
      unset(:paypal_client_id, :paypal_secret)
    elsif e.body.is_a?(Hash) && e.body['name'] == 'WEBHOOK_URL_ALREADY_EXISTS'
      nil
    else
      raise
    end
  end
end
