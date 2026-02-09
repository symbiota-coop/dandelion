module SignalMessaging
  extend ActiveSupport::Concern

  def signal_configured?
    ENV['SIGNAL_API_URL'].present? && ENV['SIGNAL_PHONE_NUMBER'].present?
  end

  def normalize_phone(phone)
    phone = phone.gsub(/[\s\-()]/, '')
    return nil unless phone.start_with?('+') || phone.start_with?('00')

    phone = phone.sub(/\A00/, '+')
    phone
  end

  def send_signal_message(recipient_phone, message)
    return unless signal_configured?

    recipient_phone = normalize_phone(recipient_phone)
    return unless recipient_phone

    conn = Faraday.new(url: ENV['SIGNAL_API_URL']) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
    end

    conn.post('/v2/send') do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = {
        message: message,
        number: ENV['SIGNAL_PHONE_NUMBER'],
        recipients: [recipient_phone]
      }
    end
  rescue StandardError => e
    Honeybadger.notify(e)
  end
end
