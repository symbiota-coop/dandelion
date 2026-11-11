# Every email Dandelion sends goes through Mailer.deliver (Dandelion/MailgunDirect), which builds the one
# Mailgun::BatchMessage, so EmailHelper::RecipientVariables makes every subject, From, Reply-To and recipient variable safe:
#
#   Mailer.deliver(:order, to: event.event_facilitators, subject: "New order for #{event.name}", locals: { order:, event:, account: })
#
# - The body is a template in app/views/emails rendered in the email layout (with locals:), or content: (HTML put in
#   the layout), html: (a finished body) or text: (a plain text body)
# - to: an Account, a list or criteria of them, an email, or [email, variables] pairs, each sent as Mailgun's :to. An
#   account gets Account#mail_variables; an email given alone gets no variables, which Mailgun numbers itself
# - stream: picks the Mailgun domain and the default sender (STREAMS); microsoft_workaround: true sends from
#   MAILGUN_MICROSOFT_HOST when the first recipient is at a Microsoft domain (EmailHelper.mailgun_host)
# - via: an organisation sends through its own Mailgun account and domain instead
# - attachments: { filename => bytes } (or [filename, bytes] pairs, where two may share a name), written to tempfiles that are removed however sending ends
# - It sends in production only, or with send_when: :configured wherever the Mailgun account has an API key (via:
#   always does), and returns Mailgun's message ids, or nil when it sends nothing
module Mailer
  # Each stream's Mailgun domain and default sender, by ENV name. Posts and pmails have no default: they say who from
  STREAMS = {
    notifications: %w[MAILGUN_NOTIFICATIONS_HOST NOTIFICATIONS_EMAIL_FULL],
    tickets: %w[MAILGUN_TICKETS_HOST TICKETS_EMAIL_FULL],
    pmails: ['MAILGUN_PMAILS_HOST', nil],
    posts: ['MAILGUN_POSTS_HOST', nil]
  }.freeze
  SEND_WHEN = %i[production configured].freeze
  # reply_to: nil still sets the header, as the senders that pass event.email || organisation.reply_to always have
  NOT_GIVEN = Object.new.freeze

  class << self
    def deliver(template = nil, to:, subject:, locals: {}, content: nil, html: nil, text: nil, stream: :notifications,
                microsoft_workaround: false, via: nil, from: nil, reply_to: NOT_GIVEN, attachments: {}, send_when: :production)
      raise ArgumentError, "Unknown stream #{stream.inspect}" unless STREAMS.key?(stream)
      raise ArgumentError, "Unknown send_when #{send_when.inspect}" unless SEND_WHEN.include?(send_when)
      raise ArgumentError, 'Give one of a template, content:, html: or text:' unless [template, content, html].compact.length <= 1 && (template || content || html || text)

      host_env, from_env = STREAMS[stream]
      from ||= ENV[from_env] if from_env

      recipients = recipients(to)
      api_key, api_host, host = mailgun_account(via, ENV[host_env])
      host = EmailHelper.mailgun_host(recipients.first&.first, host) if microsoft_workaround

      batch_message = Mailgun::BatchMessage.new(Mailgun::Client.new(api_key, api_host), host)
      batch_message.from from
      batch_message.reply_to reply_to unless reply_to.equal?(NOT_GIVEN)
      batch_message.subject subject
      body = if template
               EmailHelper.html(template, **locals)
             elsif content
               EmailHelper.html(content: content, **locals)
             else
               html
             end
      batch_message.body_html body if body
      batch_message.body_text text if text

      with_attachments(batch_message, attachments) do
        recipients.each { |email, variables| batch_message.add_recipient(:to, email, variables) }
        # Mailgun sends nothing to no one, so neither does this
        batch_message.finalize if recipients.any? && sending?(send_when, via, api_key)
      end
    end

    # [email, variables or nil] for each recipient
    def recipients(to)
      case to
      when nil then []
      when Account then [to.mail_recipient]
      when String then [[to, nil]]
      when Array
        return [to] if to.length == 2 && (to[1].is_a?(Hash) || (to[0].is_a?(String) && to[1].nil?))

        to.flat_map { |recipient| recipients(recipient) }
      else
        raise ArgumentError, "Can't send to #{to.class}" unless to.respond_to?(:each)

        to.map(&:mail_recipient)
      end
    end

    private

    # [API key, API host, domain]
    def mailgun_account(via, default_host)
      if via
        [via.mailgun_api_key, (via.mailgun_region == 'EU' ? 'api.eu.mailgun.net' : 'api.mailgun.net'), via.mailgun_domain]
      else
        [ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION'], default_host]
      end
    end

    # As the senders did: an organisation's emails and send_when: :configured go whenever there's a key (even
    # outside production), the rest only in production
    def sending?(send_when, via, api_key)
      if via || send_when == :configured
        !api_key.nil?
      else
        Padrino.env == :production
      end
    end

    def with_attachments(batch_message, attachments)
      files = []
      attachments.each do |filename, bytes|
        # The extension is how Mailgun's gem picks the attachment's content type
        file = Tempfile.new(['attachment', File.extname(filename)])
        files << file
        file.binmode
        file.write bytes
        file.rewind
        batch_message.add_attachment file, filename
      end
      yield
    ensure
      files.each(&:close!)
    end
  end
end
