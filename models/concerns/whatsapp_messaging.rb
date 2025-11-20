module WhatsappMessaging
  extend ActiveSupport::Concern

  def whatsapp_configured?
    ENV['WHATSAPP_ACCESS_TOKEN'].present? && ENV['WHATSAPP_PHONE_NUMBER_ID'].present?
  end

  def format_phone_number(phone)
    return nil unless phone.present?
    return nil unless phone.start_with?('+') || phone.start_with?('00')

    phone_number = phone.gsub(/[\s\-()]/, '')
    phone_number = phone_number[1..] if phone_number.start_with?('+')
    phone_number = phone_number[2..] if phone_number.start_with?('00')
    phone_number
  end

  def truncate_event_name_for_whatsapp(event_name, template_header)
    max_event_name_length = 60 - template_header.gsub('{{1}}', '').length
    if event_name.length > max_event_name_length
      "#{event_name[0...(max_event_name_length - 1)]}…"
    else
      event_name
    end
  end

  def send_whatsapp_template(phone_number, template_name, components)
    return unless whatsapp_configured?

    token = ENV['WHATSAPP_ACCESS_TOKEN']
    http_client = HTTP.auth("Bearer #{token}")
    messages_url = "https://graph.facebook.com/v21.0/#{ENV['WHATSAPP_PHONE_NUMBER_ID']}/messages"

    payload = {
      messaging_product: 'whatsapp',
      to: phone_number,
      type: 'template',
      template: {
        name: template_name,
        language: { code: 'en' },
        components: components
      }
    }

    http_client.post(messages_url, json: payload)
  rescue StandardError => e
    Honeybadger.notify(e)
  end
end
