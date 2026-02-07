class Activity
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include ActivityFeedbackSummaries
  include ImportFromCsv
  include SendFollowersCsv
  include ImageWithValidation
  include Searchable
  include Taggable

  taggable tagships: :activity_tagships, tag_class: ActivityTag

  belongs_to_without_parent_validation :organisation
  belongs_to_without_parent_validation :account, optional: true

  field :name, type: String
  field :email, type: String
  field :website, type: String
  field :intro_text, type: String
  field :image_uid, type: String
  field :has_image, type: Boolean
  field :privacy, type: String
  field :application_questions, type: String
  field :thank_you_message, type: String
  field :locked, type: Boolean
  field :extra_info_for_application_form, type: String
  field :extra_info_for_acceptance_email, type: String
  field :feedback_summary, type: String
  field :feedback_summary_last_refreshed_at, type: Time
  field :slug, type: String

  def self.search_fields
    %w[name]
  end

  def self.admin_fields
    {
      name: :text,
      email: :email,
      website: :url,
      extra_info_for_acceptance_email: :wysiwyg,
      extra_info_for_application_form: :wysiwyg,
      intro_text: :wysiwyg,
      image: :image,
      events: :collection,
      privacy: :select,
      application_questions: :text_area,
      thank_you_message: :wysiwyg,
      locked: :check_box
    }
  end

  def self.new_hints
    {
      locked: 'Make the activity visible to admins only',
      thank_you_message: 'Shown to applicants after they apply',
      extra_info_for_application_form: 'Shown at the top of the application form',
      extra_info_for_acceptance_email: 'Included in the email to accepted applicants'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end

  has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

  has_many :events, dependent: :nullify
  has_many :events_as_feedback_activity, class_name: 'Event', inverse_of: :feedback_activity, dependent: :nullify
  has_many :activityships, dependent: :destroy
  has_many :activity_applications, dependent: :destroy

  has_many :pmails_as_mailable, class_name: 'Pmail', as: :mailable, dependent: :destroy
  has_many :pmails_as_exclusion, class_name: 'Pmail', inverse_of: :activity, dependent: :nullify
  def pmails_including_events
    Pmail.and(:id.in => pmails_as_mailable.pluck(:id) + Pmail.and(:mailable_type => 'Event', :mailable_id.in => events.pluck(:id)).pluck(:id))
  end

  has_many_through :activity_tags, through: :activity_tagships

  with_options class_name: 'Account' do
    has_many_through :members, through: :activityships
    has_many_through :applicants, through: :activity_applications
    has_many_through :subscribed_members, through: :activityships, conditions: { unsubscribed: false }
    has_many_through :unsubscribed_members, through: :activityships, conditions: { unsubscribed: true }
    has_many_through :admins, through: :activityships, conditions: { admin: true }
    has_many_through :admins_receiving_feedback, through: :activityships, conditions: { admin: true, receive_feedback: true }
  end

  def all_feedback_event_ids
    events.pluck(:id) + events_as_feedback_activity.pluck(:id)
  end

  def event_feedbacks
    EventFeedback.and(:event_id.in => all_feedback_event_ids)
  end

  def unscoped_event_feedbacks
    EventFeedback.unscoped.and(:event_id.in => all_feedback_event_ids)
  end

  def event_tags
    EventTag.and(:id.in => EventTagship.and(:event_id.in => events.pluck(:id)).pluck(:event_tag_id))
  end

  has_many :activity_tagships, dependent: :destroy

  validates_presence_of :name, :slug
  validates_uniqueness_of :slug, scope: :organisation_id
  validates_format_of :slug, with: /\A[a-z0-9-]+\z/

  def self.active
    self.and(locked: false).and(:id.in => Event.future.pluck(:activity_id))
  end

  def self.inactive
    self.and(:id.in => Activity.and(locked: true).pluck(:id) + Activity.and(:id.nin => Event.future.pluck(:activity_id)).pluck(:id))
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

  def subscribed_accounts
    # Members subscribed to activity AND subscribed to org AND not globally unsubscribed
    subscribed_members.and(subscribed_organisation_ids_cache: organisation_id, unsubscribed: false)
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

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html EmailHelper.html(:csv)

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'applications.csv')

    batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })

    batch_message.finalize if Padrino.env == :production
    file.close
    file.unlink
  end
  handle_asynchronously :send_applications_csv
end
