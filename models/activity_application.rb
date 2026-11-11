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
    Mailer.deliver(
      :activity_application,
      to: activity.admins,
      subject: "Application to #{activity.name}",
      locals: { account: account, activity: activity, activity_application: self }
    )
  end
  handle_asynchronously :send_notification

  def accept
    activity.activityships.create account: account

    Mailer.deliver(
      :accepted,
      to: account,
      subject: "You've been accepted to #{activity.name}",
      locals: { activity: activity },
      **({ reply_to: activity.email } if activity.email)
    )
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
