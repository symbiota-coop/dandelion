class Message
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  # Per sending account (messenger): max distinct recipients (messengees) in each rolling window.
  MESSENGER_RATE_10_MIN = 10
  MESSENGER_RATE_1_HOUR = 25
  MESSENGER_RATE_24_HOURS = 50

  belongs_to_without_parent_validation :messenger, class_name: 'Account', inverse_of: :messages_as_messenger
  belongs_to_without_parent_validation :messengee, class_name: 'Account', inverse_of: :messages_as_massangee

  field :body, type: String

  before_validation do
    errors.add(:messenger, 'is not able to message') unless messenger && messenger.able_to_message
  end

  validates_presence_of :body
  validate :messenger_send_rate_limit, on: :create

  def self.read?(messenger, messengee)
    messages = Message.and(messenger: messenger, messengee: messengee).order('created_at desc')
    message = messages.first
    message_receipt = MessageReceipt.find_by(messenger: messenger, messengee: messengee)
    message && message_receipt && message_receipt.received_at > message.created_at
  end

  def self.unread?(messenger, messengee)
    !read?(messenger, messengee)
  end

  after_create :send_email
  def send_email
    return unless !messengee.unsubscribed? && !messengee.unsubscribed_messages?

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    message = self
    messenger = message.messenger
    messengee = message.messengee
    batch_message.from "#{messenger.name} <#{ENV['NOTIFICATIONS_EMAIL']}>"
    batch_message.reply_to "#{messenger.name} <#{messenger.email}>"
    batch_message.subject "[Dandelion] Message from #{messenger.name}"
    batch_message.body_html EmailHelper.html(:message, messenger: messenger, message: message)

    [messengee].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
  handle_asynchronously :send_email

  private

  def messenger_send_rate_limit
    return unless new_record? && messenger_id

    rate_limit_message = "You're sending messages too quickly. Please wait before sending more; if you need to reach many people, use your event or organisation's tools instead."

    mid = messenger_id
    scope = self.class.and(messenger_id: mid)
    recipient = messengee_id

    # rubocop:disable Style/GuardClause, Style/RedundantReturn
    if unique_recipient_cap_exceeded?(scope, 10.minutes.ago, MESSENGER_RATE_10_MIN, recipient)
      errors.add(:base, rate_limit_message)
      return
    end

    if unique_recipient_cap_exceeded?(scope, 1.hour.ago, MESSENGER_RATE_1_HOUR, recipient)
      errors.add(:base, rate_limit_message)
      return
    end

    if unique_recipient_cap_exceeded?(scope, 24.hours.ago, MESSENGER_RATE_24_HOURS, recipient)
      errors.add(:base, rate_limit_message)
      return
    end
    # rubocop:enable Style/GuardClause, Style/RedundantReturn
  end

  def unique_recipient_cap_exceeded?(messenger_scope, since, limit, recipient_id)
    recent = messenger_scope.and(:created_at.gte => since)
    distinct_recipients = recent.distinct(:messengee_id).compact
    return false if recipient_id && distinct_recipients.include?(recipient_id)

    distinct_recipients.size >= limit
  end
end
