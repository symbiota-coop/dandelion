module EmailHelper
  MICROSOFT_DOMAINS = %w[hotmail msn outlook live].freeze

  def self.mailgun_host(email, default_host)
    return default_host unless ENV['MICROSOFT_EMAIL_WORKAROUND']
    return default_host unless email

    domain = email.to_s.split('@').last.to_s.downcase
    base_domain = domain.split('.').first
    MICROSOFT_DOMAINS.include?(base_domain) ? ENV['MAILGUN_PMAILS_HOST'] : default_host
  end

  class TemplateContext
    def initialize(locals)
      locals.each do |key, value|
        define_singleton_method(key) { value }
      end
    end

    def get_binding
      binding
    end
  end

  def self.theme_css(color)
    %(
      a { color: #{color}; }
      a:hover { color: #{color.paint.darken} !important; }
      p.action a { background: #{color}; }
      p.action a:hover { background: #{color.paint.darken} !important; }
      blockquote { border-left: 0.25em solid #{color.paint.opacity(0.33)} !important; }
    )
  end

  def self.render(template_name, **locals)
    context = TemplateContext.new(locals)
    ERB.new(File.read(Padrino.root("app/views/emails/#{template_name}.erb"))).result(context.get_binding)
  end

  def self.send_to_founder(subject:, body_text: nil, body_html: nil, reply_to: nil)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject subject
    batch_message.body_text body_text if body_text
    batch_message.body_html body_html if body_html
    batch_message.reply_to reply_to if reply_to

    batch_message.add_recipient(:to, ENV['FOUNDER_EMAIL'])

    batch_message.finalize if Padrino.env == :production
  end

  def self.html(template_or_first_arg = nil, template: nil, content: nil, layout: :email, **locals, &block)
    # If first arg is a symbol or string, treat it as template name
    template = template_or_first_arg.to_s if template_or_first_arg.is_a?(Symbol) || template_or_first_arg.is_a?(String)

    raise ArgumentError, 'Either template or content must be provided' if template.nil? && content.nil? && layout == :email
    raise ArgumentError, 'Cannot provide both template and content' if template && content

    content = render(template.to_sym, **locals) if template
    content = block.call(content) if block_given?
    context = TemplateContext.new(locals.merge(content: content))

    Premailer.new(
      ERB.new(File.read(Padrino.root("app/views/layouts/#{layout}.erb"))).result(context.get_binding),
      with_html_string: true,
      adapter: 'nokogiri',
      input_encoding: 'UTF-8'
    ).to_inline_css
  end
end
