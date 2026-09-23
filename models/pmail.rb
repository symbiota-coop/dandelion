class Pmail
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  include PmailMailgun
  include Searchable
  include SignalMessaging

  belongs_to_without_parent_validation :organisation
  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :mailable, polymorphic: true, optional: true
  belongs_to_without_parent_validation :event, optional: true, inverse_of: :pmails_as_exclusion # Exclude people attending an event
  belongs_to_without_parent_validation :activity, optional: true, inverse_of: :pmails_as_exclusion # Exclude people attending upcoming events in an activity
  belongs_to_without_parent_validation :local_group, optional: true, inverse_of: :pmails_as_exclusion # Exclude people in a local group
  belongs_to_without_parent_validation :ticket_group, optional: true
  belongs_to_without_parent_validation :ticket_type, optional: true

  field :from, type: String
  field :subject, type: String
  field :preview_text, type: String
  field :recipient_kind, type: String
  field :body, type: String
  field :message_ids, type: String
  field :will_send_at, type: Time
  field :requested_send_at, type: Time
  field :sent_at, type: Time
  field :link_params, type: String
  field :markdown, type: Boolean
  field :gift, type: Boolean

  def self.protected_attributes
    %w[organisation_id account_id sent_at requested_send_at message_ids gift editor] + recipient_fields
  end

  def self.recipient_fields
    %w[recipient_kind mailable_type mailable_id ticket_group_id ticket_type_id]
  end

  def self.organisation_wide_recipient_kinds
    %w[everyone monthly_donors not_monthly_donors facilitators]
  end

  def self.event_recipient_kinds
    %w[event waitlist all_ticket_type_waitlists ticket_type_waitlist ticket_group]
  end

  def self.waitlist_recipient_kinds
    %w[waitlist all_ticket_type_waitlists ticket_type_waitlist]
  end

  def organisation_wide_recipients?
    Pmail.organisation_wide_recipient_kinds.include?(recipient_kind)
  end

  def event_recipients?
    Pmail.event_recipient_kinds.include?(recipient_kind)
  end

  def ticket_holder_recipients?
    %w[event ticket_group].include?(recipient_kind)
  end

  def recipients_admin?(account)
    if organisation_wide_recipients? || !mailable || mailable.is_a?(ActivityTag)
      Organisation.admin?(organisation, account)
    else
      mailable.class.admin?(mailable, account)
    end
  end

  def self.assignable_foreign_keys
    %w[event_id activity_id local_group_id]
  end

  has_many :pmail_links, dependent: :destroy

  def self.mailable_types
    %w[Activity ActivityTag LocalGroup Event]
  end

  def self.search_fields
    %w[subject]
  end

  validates_presence_of :from, :subject, :body
  validates_format_of :from, with: %r{\A\s*([\p{L}\d\s]+?)\s*<([\w.!#$%&â€™*+/=?^_`{|}~-]+@[\w-]+(?:\.[\w-]+)+)>\s*\Z}

  validates_same_parent :activity, via: :organisation
  validates_same_parent :local_group, via: :organisation

  attr_accessor :file, :to_option, :editor

  before_validation do
    self.will_send_at = nil if will_send_at && will_send_at < Time.now
    self.will_send_at = nil if mailable.is_a?(Event) || !organisation.mailgun_api_key

    assign_recipients_from_to_option if to_option

    errors.add(:to_option, 'is not permitted') if (changed & Pmail.recipient_fields).any? && !recipients_admin?(editor || account)
    errors.add(:event, 'must belong to the same organisation') if event && organisation && event.organisation_id != organisation_id && !Array(event.cohosts_ids_cache).include?(organisation_id)
    errors.add(:link_params, 'cannot contain spaces') if link_params && link_params.include?(' ')
  end

  def assign_recipients_from_to_option
    # Resubmitting the current selection keeps it, even if its ticket group or ticket type has since been deleted
    return if persisted? && (changed & Pmail.recipient_fields).none? && to_option == to_selected

    kind, id = to_option.split(':', 2)
    self.recipient_kind = kind
    self.mailable = nil
    self.ticket_group = nil
    self.ticket_type = nil

    case kind
    when *Pmail.organisation_wide_recipient_kinds
      return unless id
    when 'activity'
      self.mailable = organisation&.activities&.find(id)
    when 'activity_tag'
      self.mailable = organisation&.activity_tags&.find(id)
    when 'local_group'
      self.mailable = organisation&.local_groups&.find(id)
    when 'event', 'waitlist', 'all_ticket_type_waitlists'
      self.mailable = organisation&.events&.find(id)
    when 'ticket_group'
      self.ticket_group = TicketGroup.find(id)
      self.mailable = organisation&.events&.find(ticket_group.event_id) if ticket_group
    when 'ticket_type_waitlist'
      self.ticket_type = TicketType.find(id)
      self.mailable = organisation&.events&.find(ticket_type.event_id) if ticket_type
    end

    errors.add(:to_option, 'is invalid') unless mailable
  end

  def to_selected
    case recipient_kind
    when nil
      nil
    when *Pmail.organisation_wide_recipient_kinds
      recipient_kind
    when 'ticket_group'
      "ticket_group:#{ticket_group_id}"
    when 'ticket_type_waitlist'
      "ticket_type_waitlist:#{ticket_type_id}"
    else
      "#{recipient_kind}:#{mailable_id}"
    end
  end

  def reason
    event_name = "#{organisation.name}'s event #{mailable.name}" if event_recipients?
    case recipient_kind
    when 'everyone' then "following #{organisation.name}"
    when 'monthly_donors' then "a monthly donor of #{organisation.name}"
    when 'not_monthly_donors' then "not a monthly donor of #{organisation.name}"
    when 'facilitators' then "a facilitator at #{organisation.name}"
    when 'activity' then "following #{organisation.name}'s activity #{mailable.name}"
    when 'activity_tag' then "following a relevant activity at #{organisation.name}"
    when 'local_group' then "following #{organisation.name}'s local group #{mailable.name}"
    when 'ticket_group' then ticket_group ? "in the #{ticket_group.name} ticket group for #{event_name}" : "in a ticket group for #{event_name}"
    when 'ticket_type_waitlist' then ticket_type ? "on the #{ticket_type.name} waitlist for #{event_name}" : "on a ticket type waitlist for #{event_name}"
    when 'all_ticket_type_waitlists' then "on a ticket type waitlist for #{event_name}"
    when 'waitlist' then "on the waitlist for #{event_name}"
    when 'event' then "attending #{event_name}"
    end
  end

  def to
    t = case recipient_kind
        when 'everyone' then organisation.subscribed_members
        when 'monthly_donors' then organisation.subscribed_monthly_donors
        when 'not_monthly_donors' then organisation.subscribed_not_monthly_donors
        when 'facilitators' then organisation.facilitators
        when 'ticket_group' then Account.and(:id.in => ticket_group ? ticket_group.tickets.complete.pluck(:account_id).compact : [])
        when 'ticket_type_waitlist' then ticket_type ? mailable.ticket_type_waiters(ticket_type_id: ticket_type_id) : Account.and(:id.in => [])
        when 'all_ticket_type_waitlists' then mailable.ticket_type_waiters
        when 'waitlist' then mailable.waiters
        when 'activity', 'activity_tag', 'local_group', 'event' then mailable.subscribed_members
        end
    t = t.and(:id.nin => event.attendee_ids) if event
    t = t.and(:id.nin => activity.future_attendees.pluck(:id)) if activity
    t = t.and(:id.nin => local_group.member_ids) if local_group
    t
  end

  def to_with_unsubscribes
    if event_recipients?
      to
    else
      to.and(:id.nin => organisation.unsubscribed_member_ids).and(unsubscribed: false)
    end
  end

  def sendable?
    mailable.is_a?(Event) || organisation.mailgun_api_key || organisation.free_mailgun?
  end

  def event_tickets_with_email
    tickets = if recipient_kind == 'ticket_group'
                ticket_group ? ticket_group.tickets : Ticket.and(:id.in => [])
              else
                mailable.tickets
              end
    tickets.complete.and(:email.ne => nil)
  end

  def event_emails
    emails = to_with_unsubscribes.pluck(:email)
    emails += event_tickets_with_email.reject { |ticket| emails.include?(ticket.email) }.map(&:email)
    emails
  end

  def send_count
    if ticket_holder_recipients?
      event_emails.count
    else
      to_with_unsubscribes.count
    end
  end

  after_save do
    organisation.attachments.create(file: file) if file
  end

  def html(viewing_on_web: false)
    pmail = self
    html = EmailHelper.html(layout: :pmail, pmail: pmail, viewing_on_web: viewing_on_web)
    if link_params
      html.gsub(/href\s*=\s*"([^"]*)"/) do
        url = Regexp.last_match[1]
        path, query_string = url.split('?')
        begin
          url = "#{path}?#{Rack::Utils.parse_nested_query(query_string).merge(Rack::Utils.parse_nested_query(link_params)).to_query}"
        rescue StandardError
          url = "#{path}?#{query_string}"
        end
        %(href="#{url}")
      end
    else
      html
    end
  end

  def delayed_jobs
    Delayed::Job.and(handler: %r{object: !ruby/Mongoid:Pmail}).and(handler: /#{Regexp.escape(Base64.encode64(id.to_bson.to_s))}/)
  end

  def delayed_job
    raise 'Multiple delayed jobs!' if delayed_jobs.count > 1

    delayed_jobs.first
  end

  def send_pmail
    return if sent_at # if already sent

    set(requested_send_at: Time.now) unless requested_send_at

    # send_batch_message
    return unless (message_ids = send_batch_message)

    set(sent_at: Time.now)
    set(message_ids: message_ids)
  end

  def send_batch_message(test_to: nil, check_already_sent: false)
    pmail_links.destroy_all
    mailgun_sto = nil

    from_name = (from.split('<').first.strip if from.include?('<'))
    from_email = if from.include?('<')
                   from.split('<').last.split('>').first
                 else
                   from
                 end
    from_domain = from_email.split('@').last

    is_event_pmail = mailable.is_a?(Event)

    if is_event_pmail
      mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
      mailgun_host = ENV['MICROSOFT_EMAIL_WORKAROUND'] ? ENV['MAILGUN_PMAILS_HOST'] : ENV['MAILGUN_TICKETS_HOST']
      batch_message = Mailgun::BatchMessage.new(mg_client, mailgun_host)

      batch_message.from from_name ? "#{from_name} <#{ENV['MAILER_EMAIL']}>" : ENV['MAILER_EMAIL_FULL']
      batch_message.reply_to from
    elsif organisation.mailgun_api_key
      mg_client = Mailgun::Client.new organisation.mailgun_api_key, (organisation.mailgun_region == 'EU' ? 'api.eu.mailgun.net' : 'api.mailgun.net')
      batch_message = Mailgun::BatchMessage.new(mg_client, organisation.mailgun_domain)
      mailgun_sto = organisation.mailgun_sto

      if organisation.mailgun_domain == from_domain || organisation.mailgun_domain.ends_with?(".#{from_domain}")
        batch_message.from from
      else
        batch_message.from from_name ? "#{from_name} <mailer@#{organisation.mailgun_domain}>" : "mailer@#{organisation.mailgun_domain}"
        batch_message.reply_to from
      end

      if check_already_sent
        mg_events = Mailgun::Events.new(mg_client, organisation.mailgun_domain)
        options = { 'event' => 'accepted', 'tags' => id.to_s }
        recipients = []
        result = mg_events.get(options)
        result.to_h['items'].each { |item| recipients << item['recipient'] }
        while (result = mg_events.next(options))
          break if result.to_h['items'].empty?

          result.to_h['items'].each { |item| recipients << item['recipient'] }
          puts recipients.count
        end
      end
    elsif organisation.free_mailgun?(excluding_pmail: self)
      mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
      batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_PMAILS_HOST'])

      batch_message.from from_name ? "#{from_name} <mailer@#{ENV['MAILGUN_PMAILS_HOST']}>" : "mailer@#{ENV['MAILGUN_PMAILS_HOST']}"
      batch_message.reply_to from
      set(gift: true)
    end

    batch_message.subject(test_to ? "#{subject} [test sent #{Time.now}]" : subject)
    batch_message.body_html html
    batch_message.add_tag id

    batch_message.header 'o:deliverytime-optimize-period', '24h' if mailgun_sto

    if test_to
      accounts = test_to
    else
      accounts = to_with_unsubscribes
      if ticket_holder_recipients?
        emails = to_with_unsubscribes.pluck(:email)
        event_tickets_with_email.reject { |ticket| emails.include?(ticket.email) }.each do |ticket|
          batch_message.add_recipient(:to, ticket.email, {
                                        'firstname' => ticket.firstname || 'there',
                                        'footer_class' => 'd-none'
                                      })
        end
      end
    end

    accounts.each do |account|
      next if check_already_sent && recipients.include?(account.email)

      batch_message.add_recipient(:to, account.email, {
                                    'firstname' => account.firstname || 'there',
                                    'id' => account.id.to_s,
                                    'username' => account.username,
                                    'view_or_activate' => (account.has_signed_in? ? 'View your profile' : 'Activate your account'),
                                    'org_unsubscribe_token' => account.organisation_unsubscribe_token_for(organisation)
                                  })
    end

    result = batch_message.finalize if Padrino.env == :production

    send_signal_messages(accounts) if is_event_pmail

    result
  end

  def send_signal_messages(accounts)
    return unless signal_configured?
    return unless mailable.is_a?(Event)

    accounts.each do |account|
      next unless account.phone.present?

      pmail_url = "#{ENV['BASE_URI']}/pmails/#{id}"
      message = "New message about #{mailable.name}\n\nView the message '#{subject}' at #{pmail_url}"

      send_signal_message(account.phone, message)
    end
  end

  def duplicate!(account)
    duplicate_to_option = to_option || to_selected
    if duplicate_to_option&.starts_with?('ticket_group:') && !valid_ticket_group_to_option?(duplicate_to_option)
      errors.add(:base, 'This mail cannot be duplicated because its ticket group no longer exists.')
      return nil
    end
    if duplicate_to_option&.starts_with?('ticket_type_waitlist:') && !valid_ticket_type_waitlist_to_option?(duplicate_to_option)
      errors.add(:base, 'This mail cannot be duplicated because its ticket type no longer exists.')
      return nil
    end

    attributes = {
      to_option: duplicate_to_option,
      from: from,
      subject: subject,
      preview_text: preview_text,
      body: body,
      link_params: link_params,
      organisation: organisation,
      event: event,
      activity: activity,
      local_group: local_group,
      account: account
    }

    pmail = Pmail.create(attributes)
    unless pmail.persisted?
      errors.add(:base, pmail.errors.full_messages.join('; '))
      return nil
    end
    pmail
  end

  def valid_ticket_group_to_option?(to_option)
    ticket_group = TicketGroup.find(to_option.split(':').last)
    ticket_group && organisation&.events&.find(ticket_group.event_id)
  end

  def valid_ticket_type_waitlist_to_option?(to_option)
    ticket_type = TicketType.find(to_option.split(':').last)
    ticket_type && organisation&.events&.find(ticket_type.event_id)
  end

  def self.new_hints
    {
      from: "In the form <em>Maria Sabina &lt;maria.sabina@#{ENV['DOMAIN']}&gt;</em>",
      link_params: 'For example: utm_source=newsletter&utm_medium=email&utm_campaign=launch',
      preview_text: 'Appears alongside the subject line in some email clients'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end

  def self.human_attribute_name(attr, options = {})
    {
      to_option: 'To',
      event_id: 'Exclude people attending this event',
      activity_id: 'Exclude people attending upcoming events in this activity',
      local_group_id: 'Exclude people in this local group',
      link_params: 'Parameters to add to links'
    }[attr.to_sym] || super
  end
end
