class Activity
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  include ActivityFeedbackSummaries
  include ImportFromCsv
  include SendFollowersCsv
  include ImageWithValidation

  belongs_to :organisation, index: true
  belongs_to :account, index: true, optional: true

  field :name, type: String
  field :email, type: String
  field :website, type: String
  field :telegram_group, type: String
  field :intro_text, type: String
  field :image_uid, type: String
  field :hide_members, type: Boolean
  field :privacy, type: String
  field :application_questions, type: String
  field :thank_you_message, type: String
  field :hidden, type: Boolean
  field :extra_info_for_application_form, type: String
  field :extra_info_for_acceptance_email, type: String
  field :feedback_summary, type: String
  field :slug, type: String

  def self.admin_fields
    {
      name: :text,
      email: :email,
      website: :url,
      extra_info_for_acceptance_email: :wysiwyg,
      extra_info_for_application_form: :wysiwyg,
      telegram_group: :url,
      intro_text: :wysiwyg,
      image: :image,
      events: :collection,
      hide_members: :check_box,
      privacy: :select,
      application_questions: :text_area,
      thank_you_message: :wysiwyg,
      hidden: :check_box
    }
  end

  has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

  has_many :events, dependent: :nullify
  has_many :events_as_feedback_activity, class_name: 'Event', dependent: :nullify
  has_many :event_feedbacks, dependent: :destroy
  has_many :activityships, dependent: :destroy
  has_many :activity_applications, dependent: :destroy

  has_many :pmails_as_mailable, class_name: 'Pmail', as: :mailable, dependent: :destroy
  has_many :pmails_as_exclusion, class_name: 'Pmail', inverse_of: :activity, dependent: :nullify
  def pmails_including_events
    Pmail.and(:id.in => pmails_as_mailable.pluck(:id) + Pmail.and(:mailable_type => 'Event', :mailable_id.in => events.pluck(:id)).pluck(:id))
  end

  def event_tags
    EventTag.and(:id.in => EventTagship.and(:event_id.in => events.pluck(:id)).pluck(:event_tag_id))
  end

  has_many :activity_tagships, dependent: :destroy
  attr_accessor :tag_names

  after_save :update_activity_tags
  def update_activity_tags
    @tag_names ||= ''
    @tag_names_a = @tag_names.split(',')
    current_tag_names = activity_tagships.map(&:activity_tag_name)
    tags_to_remove = current_tag_names - @tag_names_a
    tags_to_add = @tag_names_a - current_tag_names
    tags_to_remove.each do |name|
      activity_tag = ActivityTag.find_by(name: name)
      activity_tagships.find_by(activity_tag: activity_tag).destroy
    end
    tags_to_add.each do |name|
      if (activity_tag = ActivityTag.find_or_create_by(name: name)).persisted?
        activity_tagships.create(activity_tag: activity_tag)
      end
    end
  end

  def activity_tags
    ActivityTag.and(:id.in => activity_tagships.pluck(:activity_tag_id))
  end

  validates_presence_of :name, :slug
  validates_uniqueness_of :slug, scope: :organisation_id
  validates_format_of :slug, with: /\A[a-z0-9-]+\z/

  def self.active
    self.and(:hidden.ne => true).and(:id.in => Event.future.pluck(:activity_id))
  end

  def self.inactive
    self.and(:id.in => Activity.and(hidden: true).pluck(:id) + Activity.and(:id.nin => Event.future.pluck(:activity_id)).pluck(:id))
  end

  def application_questions_a
    q = (application_questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  def self.admin?(activity, account)
    account && activity &&
      (
        account.admin? ||
        activity.activityships.find_by(account: account, admin: true) ||
        Organisation.admin?(activity.organisation, account)
      )
  end

  def future_attendees
    Account.and(:id.in => Ticket.and(:event_id.in => events.live.public.future.pluck(:id)).pluck(:account_id))
  end

  def members
    Account.and(:id.in => activityships.pluck(:account_id))
  end

  def subscribed_members
    Account.and(:id.in => activityships.and(:unsubscribed.ne => true).pluck(:account_id))
  end

  def subscribed_accounts
    subscribed_members.and(:id.in => organisation.subscribed_accounts.pluck(:id))
  end

  def unsubscribed_members
    Account.and(:id.in => activityships.and(unsubscribed: true).pluck(:account_id))
  end

  def admins
    Account.and(:id.in => activityships.and(admin: true).pluck(:account_id))
  end

  def admins_receiving_feedback
    Account.and(:id.in => activityships.and(admin: true).and(receive_feedback: true).pluck(:account_id))
  end

  def sync_activityships
    return unless privacy == 'open'

    events.each do |event|
      event.tickets.each do |ticket|
        activityships.create account: ticket.account
      end
      event.orders.each do |order|
        activityships.create account: order.account
      end
    end
  end
  handle_asynchronously :sync_activityships

  def self.privacies
    { 'Anyone can join' => 'open', 'People must apply to join' => 'closed', 'Invitation-only' => 'secret' }
  end

  def self.human_attribute_name(attr, options = {})
    {
      privacy: 'Access',
      telegram_group: 'Telegram group/channel URL',
      email: 'Contact email',
      slug: 'URL'
    }[attr.to_sym] || super
  end

  def send_applications_csv(account)
    csv = CSV.generate do |csv|
      csv << %w[name firstname lastname email location gender application_date word_count status statused_by statused_at answers]
      activity_applications.each do |activity_application|
        csv << [
          activity_application.account.name,
          activity_application.account.firstname,
          activity_application.account.lastname,
          activity_application.account.email,
          activity_application.account.location,
          activity_application.account.gender,
          activity_application.created_at.to_fs(:db_local),
          activity_application.word_count,
          activity_application.status,
          activity_application.statused_by.try(:name),
          (activity_application.statused_at.to_fs(:db_local) if activity_application.statused_at),
          activity_application.answers
        ]
      end
    end

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    content = ERB.new(File.read(Padrino.root('app/views/emails/csv.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'applications.csv')

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    file.close
    file.unlink
  end
  handle_asynchronously :send_applications_csv
end
