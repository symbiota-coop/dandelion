class AccountContribution
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :event, optional: true
  belongs_to_without_parent_validation :event_feedback, optional: true

  field :amount, type: Float
  field :currency, type: String
  field :session_id, type: String
  field :payment_intent, type: String
  field :coinbase_checkout_id, type: String
  field :payment_completed, type: Boolean
  field :source, type: String

  def self.admin_fields
    {
      session_id: :text,
      payment_intent: :text,
      coinbase_checkout_id: :text,
      payment_completed: :check_box,
      account_id: :lookup,
      currency: :text,
      amount: :number,
      source: :text,
      event_id: :lookup,
      event_feedback_id: :lookup
    }
  end

  before_validation do
    if source
      if source.starts_with?('event:')
        self.event = Event.find(source.split(':')[1])
      elsif source.starts_with?('event_feedback:')
        self.event = event_feedback.event if (self.event_feedback = EventFeedback.find(source.split(':')[1]))
      end
    end
  end

  def body_text
    b = "Account: #{ENV['BASE_URI']}/u/#{account.username}"
    if event
      b << "\nEvent name: #{event.name}" if event
      b << "\nEvent URL: #{ENV['BASE_URI']}/e/#{event.slug}" if event
      b << "\nEvent Feedback URL: #{ENV['BASE_URI']}/event_feedbacks/#{event_feedback.id}" if event_feedback
    else
      b << "\nSource: #{source}"
    end
    b
  end

  validates_presence_of :amount, :currency

  def send_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "[Account] #{account.name} made a contribution of #{amount} #{currency}"
    batch_message.body_text body_text

    Account.and(admin: true).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
  handle_asynchronously :send_notification
end
