class Message
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :messenger, class_name: 'Account', inverse_of: :messages_as_messenger, index: true
  belongs_to_without_parent_validation :messengee, class_name: 'Account', inverse_of: :messages_as_massangee, index: true

  field :body, type: String

  def self.admin_fields
    {
      messenger_id: :lookup,
      messengee_id: :lookup,
      body: :text_area
    }
  end

  before_validation do
    errors.add(:messenger, 'is not able to message') unless messenger && messenger.able_to_message
  end

  validates_presence_of :body

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
    content = ERB.new(File.read(Padrino.root('app/views/emails/message.erb'))).result(binding)
    batch_message.from "#{messenger.name} <#{ENV['NOTIFICATIONS_EMAIL']}>"
    batch_message.reply_to "#{messenger.name} <#{messenger.email}>"
    batch_message.subject "[Dandelion] Message from #{messenger.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [messengee].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_email
end
