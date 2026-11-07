# Reads the replies to comment emails that Mailgun posts to /inbound/:id
class EmailReceiver
  # The reply as [mail, html, plain_text, envelope_sender], or nil unless Mailgun signed the request
  def self.receive(request)
    return unless signed_by_mailgun?(request.params)

    new(request).receive(mail_from_params(request.params))
  end

  # Mailgun signs each webhook with an HMAC-SHA256 of its timestamp and token, keyed with the webhook signing key
  def self.signed_by_mailgun?(params)
    key = ENV['MAILGUN_WEBHOOK_SIGNING_KEY']
    return false if key.blank? || params['signature'].blank?

    expected = OpenSSL::HMAC.hexdigest('SHA256', key, "#{params['timestamp']}#{params['token']}")
    Rack::Utils.secure_compare(expected, params['signature'].to_s)
  end

  # The message from the parsed fields Mailgun posts: its headers, plain text and HTML (attachments aren't read)
  def self.mail_from_params(params)
    text = params['body-plain']
    html = params['body-html']
    header_fields = JSON.parse(params['message-headers'].to_s).to_h
    Mail.new do
      headers header_fields
      body text
      if html
        html_part do
          content_type 'text/html; charset=UTF-8'
          body html
        end
      end
    end
  end

  def initialize(request)
    @envelope_sender = self.class.authenticated_envelope_sender(request)
  end

  # Webhook signing only proves Mailgun sent the request. Trust MAIL FROM only
  # when Mailgun SPF passed and it matches MIME From.
  def self.authenticated_envelope_sender(request)
    sender = normalize_envelope_sender(request.params['sender'])
    from = normalize_envelope_sender(request.params['from'])
    return unless sender && from && sender == from
    return unless spf_pass?(request)

    sender
  end

  def self.normalize_envelope_sender(sender)
    raw = sender.to_s.strip
    return if raw.blank?

    email = raw[/<([^>]+)>/, 1] || raw
    email = email.downcase.strip
    return unless EmailAddress.valid?(email)

    email
  end

  def self.spf_pass?(request)
    mailgun_header(request, 'x-mailgun-spf').to_s.casecmp('pass').zero?
  end

  def self.mailgun_header(request, name)
    pairs = JSON.parse(request.params['message-headers'].to_s)
    return unless pairs.is_a?(Array)

    pair = pairs.find { |entry| entry.is_a?(Array) && entry[0].to_s.downcase == name }
    pair && pair[1]
  rescue JSON::ParserError, TypeError
    nil
  end

  def receive(mail)
    if mail.html_part
      body = mail.html_part.body
      charset = mail.html_part.charset
      nl2br = false
    elsif mail.text_part
      body = mail.text_part.body
      charset = mail.text_part.charset
      nl2br = true
    else
      body = mail.body
      charset = mail.charset
      nl2br = true
    end
    html = begin; body.decoded.force_encoding(charset).encode('UTF-8'); rescue StandardError; body.to_s; end
    html = html.gsub("\n", "<br>\n") if nl2br
    html = html.gsub('<o:p>', '')
    html = html.gsub(%r{</o:p>}, '')
    begin
      # include_link_tags: false, otherwise Premailer reads <link href> paths off disk (e.g. /dev/zero)
      html = Premailer.new(html, with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8', include_link_tags: false).to_inline_css
    rescue StandardError => e
      ErrorReporting.capture_exception(e)
    end

    [/Reply above this line/, /On.+, .+ wrote:/].each do |pattern|
      html = html.split(pattern).first
    end

    html = Nokogiri::HTML.parse(html)
    html.search('style').remove
    html.search('.gmail_extra').remove
    html = html.search('body').inner_html

    plain_text = Premailer.new(html, with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8', include_link_tags: false).to_plain_text

    [mail, html, plain_text, @envelope_sender]
  end
end
