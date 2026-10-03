module EmailHelper
  MICROSOFT_DOMAINS = %w[hotmail msn outlook live].freeze
  # Mailgun fills %recipient.x% into a batch message wherever it appears. Variables on this list are harmless if
  # untrusted text uses them (organisers write "Dear %recipient.firstname%"); every other variable, including
  # tokens and anything added later, only works when it comes from Dandelion's own templates and code
  PUBLIC_RECIPIENT_VARIABLES = %w[firstname lastname fullname username id view_or_activate event_when ticket_or_tickets tickets_are description_elements].freeze
  PUBLIC_NAMES = "(?:#{PUBLIC_RECIPIENT_VARIABLES.join('|')})%".freeze
  # Tested against Mailgun (Oct 2026): in the body a value that is itself a variable is filled in too, and the
  # subject is rescanned, so text and values that join into %recipient.token% are filled in there. Joining needs a %
  # followed by r once values are in. Values can't supply a % (recipient_value), so it would have to be the text's
  # right before a public variable ('%%recipient.lastname%' with a lastname of 'recipient.token'), hence not preceded
  # by %, or the variable's own closing % ('%recipient.username%recipient%recipient.fullname%' with a fullname of
  # '.token'), hence not followed by a letter
  PUBLIC_RECIPIENT_VARIABLE = /(?<!%)%recipient\.#{PUBLIC_NAMES}(?![A-Za-z_])/i
  OTHER_RECIPIENT_VARIABLE = /%recipient\.(?!#{PUBLIC_NAMES})\w+%/i

  # The one way to make text from anyone other than Dandelion safe to put in an email: names, subjects, organiser
  # rich text, comments. Run it before adding Dandelion's own %recipient.token% links, never after.
  # Puts a zero-width non-joiner after each % that could open a variable (followed by a letter or _), unless it's a
  # %XX URL escape or opens a public variable, so Mailgun can't substitute it. CSS like width: 50%; is untouched. Premailer/Nokogiri decode &#37; back to %, so HTML-escaping alone isn't enough.
  # strip: true deletes non-public variables instead, for values that are stored rather than sent (e.g. names);
  # it repeats so '%recipient.tok%recipient.token%en%' can't reassemble
  def self.untrusted(text, strip: false)
    s = text.to_s
    if strip
      s = s.gsub(OTHER_RECIPIENT_VARIABLE, '') while s.match?(OTHER_RECIPIENT_VARIABLE)
      s
    else
      s.gsub(/#{PUBLIC_RECIPIENT_VARIABLE}|%(?=[A-Za-z_])(?![0-9A-Fa-f]{2})/) { |m| m == '%' ? "%\u200C" : m }
    end
  end

  # ::SafeBuffer is Padrino::SafeBuffer when Padrino loads before ActiveSupport's output_safety (as it currently does),
  # whose #concat calls html_escape_interpolated_argument. If the load order changes it becomes ActiveSupport::SafeBuffer,
  # whose #concat (8.1+) calls implicit_html_escape_interpolated_argument instead, so both are overridden. See issue #249
  class SafeBuffer < ::SafeBuffer
    private

    def html_escape_interpolated_argument(arg)
      escaped = super
      arg.html_safe? ? escaped : EmailHelper.untrusted(escaped)
    end

    def implicit_html_escape_interpolated_argument(arg)
      escaped = super
      arg.html_safe? ? escaped : EmailHelper.untrusted(escaped)
    end
  end

  # Plain text from anyone other than Dandelion (names, comments, websites) going into email HTML
  def self.h(text)
    untrusted(ERB::Util.html_escape(text)).html_safe
  end

  # A %recipient.x% value, e.g. a name: zero-width non-joiners on both sides of every % so it can neither open nor
  # close a variable with the text or values around it ('% recipient.token%' gives a firstname of '%' and a lastname
  # of 'recipient.token%'). Tokens, ids and Dandelion's own strings have no % so are unchanged
  def self.recipient_value(value)
    value.to_s.gsub(/\u200C?%\u200C?/, "\u200C%\u200C")
  end

  # Every sender's Mailgun recipient variables and subject pass through here. Subjects interpolate names and
  # organiser text, and no subject needs a non-public variable
  module RecipientVariables
    def add_recipient(recipient_type, address, variables = nil)
      variables = variables.transform_values { |value| value.is_a?(String) ? EmailHelper.recipient_value(value) : value } if variables.is_a?(Hash)
      super
    end

    def subject(subj = nil)
      super(subj && EmailHelper.untrusted(subj))
    end
  end
  Mailgun::BatchMessage.prepend(RecipientVariables)

  # Organiser/user rich text (CKEditor HTML) for emails: sanitized, made untrusted, email-friendly markup
  def self.rich_text(html)
    return html unless html

    html = untrusted(Sanitize.fragment(html, Sanitize::Config::DANDELION))
    replace_youtube_oembeds(html)
      .gsub(/<figure([^>]*)>/, '<div\1>')
      .gsub('</figure>', '</div>')
      .gsub(/<figcaption([^>]*)>/, '<span\1>')
      .gsub('</figcaption>', '</span>')
      .html_safe
  end

  def self.replace_youtube_oembeds(html)
    html.gsub(%r{<oembed url="https://(?:youtu\.be/|www\.youtube\.com/watch\?v=)(\w+)"></oembed>}) do
      video_id = ::Regexp.last_match(1)
      begin
        title = h(Yt::Video.new(id: video_id).title)
        %(<div><a href="https://www.youtube.com/watch?v=#{video_id}"><img src="#{ENV['BASE_URI']}/youtube_thumb/#{video_id}"></a><span>#{title}</span></div>)
      rescue Yt::Errors::NoItems
        %(<div><a href="https://www.youtube.com/watch?v=#{video_id}">link to private YouTube video</a></div>)
      end
    end
  end

  def self.mailgun_host(email, default_host)
    return default_host unless ENV['MICROSOFT_EMAIL_WORKAROUND']
    return default_host unless email

    domain = email.to_s.split('@').last.to_s.downcase
    base_domain = domain.split('.').first
    MICROSOFT_DOMAINS.include?(base_domain) ? ENV['MAILGUN_MICROSOFT_HOST'] : default_host
  end

  class TemplateContext
    def initialize(locals)
      locals.each do |key, value|
        define_singleton_method(key) { value }
      end
    end

    def h(text)
      EmailHelper.h(text)
    end

    def nl2br(text)
      h(text).gsub("\n", '<br />').html_safe
    end
  end

  # Email templates render through the same SafeBuffer-aware Erubi engine Padrino uses for web views:
  # <%= %> escapes anything that isn't html_safe, <%== %> emits raw HTML.
  # Escaping at output is what keeps user-supplied text (names, subjects, answers) inert
  # once Premailer/Nokogiri re-parses the body, regardless of how the text was stored.
  def self.render_erb(path, context)
    src = Padrino::Rendering::SafeErubi.new(File.read(path), bufval: 'EmailHelper::SafeBuffer.new', bufvar: '@_out_buf').src
    context.instance_eval(src, path)
  end

  # Emails can't use custom properties, so the theme ramp's steps are approximated here: the 600 for hovers is the
  # theme darkened 5%, and the 200 for blockquote borders is the theme at 33%, which on an email's white is the same
  # as mixing it two-thirds of the way to white
  def self.theme_css(color)
    hover = color.paint.darken(5)
    %(
      a { color: #{color}; }
      a:hover { color: #{hover} !important; }
      p.action a { background: #{color}; }
      p.action a:hover { background: #{hover} !important; }
      blockquote { border-left: 0.25em solid #{color.paint.opacity(0.33)} !important; }
    )
  end

  def self.render(template_name, **locals)
    render_erb(Padrino.root("app/views/emails/#{template_name}.erb"), TemplateContext.new(locals))
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
      render_erb(Padrino.root("app/views/layouts/#{layout}.erb"), context).to_str,
      with_html_string: true,
      adapter: 'nokogiri',
      input_encoding: 'UTF-8',
      include_link_tags: false # otherwise Premailer reads <link href> paths off disk (e.g. /dev/zero)
    ).to_inline_css
  end
end
