class ActivityApplication
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :activity, index: true
  belongs_to :account, class_name: 'Account', inverse_of: :activity_applications, index: true
  belongs_to :statused_by, class_name: 'Account', inverse_of: :statused_activity_applications, index: true, optional: true

  field :answers, type: Array
  field :status, type: String
  field :statused_at, type: Time
  field :word_count, type: Integer

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

  def self.marker_color
    '#00B963'
  end

  def self.marker_icon
    'fa fa-user'
  end

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
    self.word_count = answers.map { |_q, a| a }.join(' ').split(' ').count
  end

  def self.human_attribute_name(attr, options = {})
    {
    }[attr.to_sym] || super
  end

  after_create :send_notification
  def send_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    activity_application = self
    activity = activity_application.activity
    account = activity_application.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/activity_application.erb'))).result(binding)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject "Application to #{activity.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    activity.admins.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_notification

  def accept
    activity.activityships.create account: account

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    activity_application = self
    activity = activity_application.activity
    account = activity_application.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/accepted.erb'))).result(binding)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.reply_to activity.email if activity.email
    batch_message.subject "You've been accepted to #{activity.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
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
