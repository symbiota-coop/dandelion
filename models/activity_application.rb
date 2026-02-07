class ActivityApplication
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :activity
  belongs_to_without_parent_validation :account, class_name: 'Account', inverse_of: :activity_applications
  belongs_to_without_parent_validation :statused_by, class_name: 'Account', inverse_of: :statused_activity_applications, optional: true

  field :answers, type: Array
  field :status, type: String
  field :statused_at, type: Time
  field :word_count, type: Integer
  field :via, type: String

  def self.admin_fields
    {
      account_id: :lookup,
      status: :select,
      statused_at: :datetime,
      answers: { type: :text_area, disabled: true }
    }
  end

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  def coordinates
    account.coordinates
  end

  def lat
    coordinates[1] if coordinates
  end

  def lng
    coordinates[0] if coordinates
  end

  before_validation do
    self.word_count = answers.map { |_q, a| a }.join(' ').split.count if answers
  end

  def self.human_attribute_name(attr, options = {})
    {}[attr.to_sym] || super
  end

  after_create :send_notification
  def send_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    activity_application = self
    activity = activity_application.activity
    account = activity_application.account
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Application to #{activity.name}"
    batch_message.body_html EmailHelper.html(:activity_application, account: account, activity: activity, activity_application: activity_application)

    activity.admins.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
  handle_asynchronously :send_notification

  def accept
    activity.activityships.create account: account

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    activity_application = self
    activity = activity_application.activity
    account = activity_application.account
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.reply_to activity.email if activity.email
    batch_message.subject "You've been accepted to #{activity.name}"
    batch_message.body_html EmailHelper.html(:accepted, activity: activity)

    batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })

    batch_message.finalize if Padrino.env == :production
  end

  def self.statuses
    ['Pending', 'To interview', 'On hold', 'Accepted', 'Rejected, to contact', 'Rejected, contacted']
  end

  def self.outstanding
    self.and(:status.nin => ['Rejected, to contact', 'Rejected, contacted'])
  end

  def self.pending
    self.and(status: 'Pending')
  end

  def self.interview_arranged
    self.and(status: 'Interview arranged')
  end

  def self.accepted
    self.and(status: 'Accepted')
  end

  def accepted?
    status == 'Accepted'
  end

  def self.rejected
    self.and(:status.in => ['Rejected, to contact', 'Rejected, contacted'])
  end

  def rejected?
    ['Rejected, to contact', 'Rejected, contacted'].include?(status)
  end

  def discussers
    activity.admins
  end
end
