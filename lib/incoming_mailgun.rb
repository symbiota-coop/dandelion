class EmailReceiver < Incoming::Strategies::Mailgun
  setup api_key: ENV['MAILGUN_API_KEY']
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
      html = Premailer.new(html, with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
    rescue StandardError => e
      Airbrake.notify(e)
    end

    [/Reply above this line/, /On.+, .+ wrote:/].each do |pattern|
      html = html.split(pattern).first
    end

    html = Nokogiri::HTML.parse(html)
    html.search('style').remove
    html.search('.gmail_extra').remove
    html = html.search('body').inner_html

    plain_text = Premailer.new(html, with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_plain_text

    [mail, html, plain_text]
  end
end
