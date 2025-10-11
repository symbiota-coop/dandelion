class Pmail
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  include PmailMailgun
  include Searchable

  belongs_to_without_parent_validation :organisation, index: true
  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :mailable, polymorphic: true, index: true, optional: true
  belongs_to_without_parent_validation :event, index: true, optional: true, inverse_of: :pmails_as_exclusion # Exclude people attending an event
  belongs_to_without_parent_validation :activity, index: true, optional: true, inverse_of: :pmails_as_exclusion # Exclude people attending upcoming events in an activity
  belongs_to_without_parent_validation :local_group, index: true, optional: true, inverse_of: :pmails_as_exclusion # Exclude people in a local group

  field :from, type: String
  field :subject, type: String
  field :preview_text, type: String
  field :everyone, type: Boolean
  field :monthly_donors, type: Boolean
  field :not_monthly_donors, type: Boolean
  field :facilitators, type: Boolean
  field :waitlist, type: Boolean
  field :body, type: String
  field :message_ids, type: String
  field :will_send_at, type: Time
  field :requested_send_at, type: Time
  field :sent_at, type: Time
  field :link_params, type: String
  field :markdown, type: Boolean
  field :gift, type: Boolean

  def self.admin_fields
    {
      subject: :text,
      from: :text,
      preview_text: :text,
      gift: :check_box,
      body: :text_area,
      everyone: :check_box,
      monthly_donors: :check_box,
      not_monthly_donors: :check_box,
      facilitators: :check_box,
      waitlist: :check_box,
      link_params: :text,
      will_send_at: :datetime,
      requested_send_at: :datetime,
      sent_at: :datetime,
      message_ids: :text_area,
      markdown: :check_box,
      account_id: :lookup,
      organisation_id: :lookup
    }
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

  attr_accessor :file, :to_option

  before_validation do
    errors.add(:link_params, 'cannot contain spaces') if link_params && link_params.include?(' ')

    self.will_send_at = nil if will_send_at && will_send_at < Time.now
    self.will_send_at = nil if mailable.is_a?(Event) || !organisation.mailgun_api_key

    if to_option
      self.everyone = nil
      self.monthly_donors = nil
      self.not_monthly_donors = nil
      self.facilitators = nil
      self.waitlist = nil
      self.mailable = nil
      if to_option == 'everyone'
        self.everyone = true
      elsif to_option == 'monthly_donors'
        self.monthly_donors = true
      elsif to_option == 'not_monthly_donors'
        self.not_monthly_donors = true
      elsif to_option == 'facilitators'
        self.facilitators = true
      elsif to_option.starts_with?('activity:')
        self.mailable_type = 'Activity'
        self.mailable_id = to_option.split(':').last
      elsif to_option.starts_with?('activity_tag:')
        self.mailable_type = 'ActivityTag'
        self.mailable_id = to_option.split(':').last
      elsif to_option.starts_with?('local_group:')
        self.mailable_type = 'LocalGroup'
        self.mailable_id = to_option.split(':').last
      elsif to_option.starts_with?('event:')
        self.mailable_type = 'Event'
        self.mailable_id = to_option.split(':').last
      elsif to_option.starts_with?('waitlist:')
        self.mailable_type = 'Event'
        self.mailable_id = to_option.split(':').last
        self.waitlist = true
      end
    end
  end

  def to_selected
    if everyone
      'everyone'
    elsif monthly_donors
      'monthly_donors'
    elsif not_monthly_donors
      'not_monthly_donors'
    elsif facilitators
      'facilitators'
    elsif mailable.is_a?(Activity)
      "activity:#{mailable_id}"
    elsif mailable.is_a?(ActivityTag)
      "activity_tag:#{mailable_id}"
    elsif mailable.is_a?(LocalGroup)
      "local_group:#{mailable_id}"
    elsif mailable.is_a?(Event)
      waitlist ? "waitlist:#{mailable_id}" : "event:#{mailable_id}"
    end
  end

  def reason
    if everyone
      "following #{organisation.name}"
    elsif monthly_donors
      "a monthly donor of #{organisation.name}"
    elsif not_monthly_donors
      "not a monthly donor of #{organisation.name}"
    elsif facilitators
      "a facilitator at #{organisation.name}"
    elsif mailable.is_a?(Activity)
      "following #{organisation.name}'s activity #{mailable.name}"
    elsif mailable.is_a?(ActivityTag)
      "following a relevant activity at #{organisation.name}"
    elsif mailable.is_a?(LocalGroup)
      "following #{organisation.name}'s local group #{mailable.name}"
    elsif mailable.is_a?(Event)
      waitlist ? "on the waitlist for #{organisation.name}'s event #{mailable.name}" : "attending #{organisation.name}'s event #{mailable.name}"
    end
  end

  def to
    t = if everyone
          organisation.subscribed_members
        elsif monthly_donors
          organisation.subscribed_monthly_donors
        elsif not_monthly_donors
          organisation.subscribed_not_monthly_donors
        elsif facilitators
          organisation.facilitators
        elsif mailable
          mailable.is_a?(Event) && waitlist ? mailable.waiters : mailable.subscribed_members
        end
    t = t.and(:id.nin => event.attendees.pluck(:id)) if event
    t = t.and(:id.nin => activity.future_attendees.pluck(:id)) if activity
    t = t.and(:id.nin => local_group.members.pluck(:id)) if local_group
    t
  end

  def to_with_unsubscribes
    if mailable.is_a?(Event)
      to
    else
      to.and(:id.nin => organisation.unsubscribed_members.pluck(:id)).and(:unsubscribed.ne => true)
    end
  end

  def sendable?
    mailable.is_a?(Event) || organisation.mailgun_api_key || organisation.free_mailgun?
  end

  def event_emails
    emails = to_with_unsubscribes.pluck(:email)
    emails += mailable.tickets.complete.and(:email.ne => nil).reject { |ticket| emails.include?(ticket.email) }.map(&:email)
    emails
  end

  def send_count
    if mailable.is_a?(Event) && !waitlist
      event_emails.count
    else
      to_with_unsubscribes.count
    end
  end

  def body_with_additions
    b = body
    # replace youtu.be links with youtube.com links
    b = b.gsub(%r{<oembed url="https://youtu\.be/(\w+)"></oembed>}) do |match|
      video_id = match.match(%r{<oembed url="https://youtu\.be/(\w+)"></oembed>})[1]
      %(<oembed url="https://www.youtube.com/watch?v=#{video_id}"></oembed>)
    end
    # replace youtube.com links with embeds
    b = b.gsub(%r{<oembed url="https://www\.youtube\.com/watch\?v=(\w+)"></oembed>}) do |match|
      video_id = match.match(%r{<oembed url="https://www\.youtube\.com/watch\?v=(\w+)"></oembed>})[1]
      title = Yt::Video.new(id: video_id).title
      "<figure><a href=\"https://www.youtube.com/watch?v=#{video_id}\"><img src=\"#{ENV['BASE_URI']}/youtube_thumb/#{video_id}\"></a><figcaption>#{title}</figcaption></figure>"
    end
    # replace all figures with divs
    b = b.gsub(/<figure([^>]*)>/, '<div\1>')
    b = b.gsub('</figure>', '</div>')
    # replace all figcaptions with divs
    b = b.gsub(/<figcaption([^>]*)>/, '<span\1>')
    b.gsub('</figcaption>', '</span>')
  end

  after_save do
    organisation.attachments.create(file: file) if file
  end

  def html(share_buttons: false)
    pmail = self
    html = Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/pmail.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
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

    update_attribute(:requested_send_at, Time.now) unless requested_send_at

    # send_batch_message
    return unless (message_ids = send_batch_message)

    update_attribute(:sent_at, Time.now)
    update_attribute(:message_ids, message_ids)
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

    if mailable.is_a?(Event)
      mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
      batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_TICKETS_HOST'])

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
          break if result.to_h['items'].count == 0

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
      if mailable.is_a?(Event) && !waitlist
        emails = to_with_unsubscribes.pluck(:email)
        mailable.tickets.complete.and(:email.ne => nil).reject { |ticket| emails.include?(ticket.email) }.each do |ticket|
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
                                    'token' => account.sign_in_token,
                                    'id' => account.id.to_s,
                                    'username' => account.username,
                                    'view_or_activate' => (account.sign_ins_count.zero? ? 'Activate your account' : 'View your profile')
                                  })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def duplicate!(account)
    Pmail.create!(
      to_option: to_option,
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
    )
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
