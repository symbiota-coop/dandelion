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

  # One phone or many: many get the same message in one request, rather than a request each
  def send_signal_message(recipient_phones, message)
    return unless signal_configured?

    recipients = Array(recipient_phones).filter_map { |phone| normalize_phone(phone) }.uniq
    return if recipients.empty?

    # signal-cli sends to each recipient in turn before the API answers, so a pmail's one request to all its
    # recipients can take minutes: wait in proportion, rather than Net::HTTP's default 60 s, but within
    # Delayed::Worker.max_run_time
    conn = Faraday.new(url: ENV['SIGNAL_API_URL']) do |f|
      f.request :json
      f.response :json
      f.options.open_timeout = 10
      f.options.timeout = signal_send_timeout(recipients.count)
      f.adapter Faraday.default_adapter
    end

    conn.post('/v2/send') do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = {
        message: message,
        number: ENV['SIGNAL_PHONE_NUMBER'],
        recipients: recipients
      }
    end
  rescue StandardError => e
    ErrorReporting.capture_exception(e, context: { recipients: recipients&.count })
  end

  def signal_send_timeout(recipient_count)
    (60 + (recipient_count * 5)).clamp(60, 10.minutes.to_i)
  end
end
