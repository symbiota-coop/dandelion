class AccountContribution
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, optional: true
  belongs_to_without_parent_validation :event, optional: true
  belongs_to_without_parent_validation :event_feedback, optional: true

  field :amount, type: Float
  field :currency, type: String
  field :session_id, type: String
  field :payment_intent, type: String
  field :coinbase_checkout_id, type: String
  field :payment_completed, type: Boolean
  field :source, type: String

  before_validation do
    if source
      if source.starts_with?('event:')
        self.event = Event.find(source.split(':')[1])
      elsif source.starts_with?('event_feedback:')
        if (self.event_feedback = EventFeedback.find(source.split(':')[1]))
          self.event = event_feedback.event
          self.account ||= event_feedback.account
        end
      end
    end
  end

  def body_text
    lines = []
    lines << "Account: #{ENV['BASE_URI']}/u/#{account.username}" if account
    if event
      lines << "Event name: #{event.name}"
      lines << "Event URL: #{ENV['BASE_URI']}/e/#{event.slug}"
      lines << "Event Feedback URL: #{ENV['BASE_URI']}/event_feedbacks/#{event_feedback.id}" if event_feedback
    else
      lines << "Source: #{source}"
    end
    lines.join("\n")
  end

  validates_presence_of :amount, :currency

  def send_notification
    Mailer.deliver(
      to: Account.and(admin: true),
      subject: if account
                 "[Account] #{account.name} made a contribution of #{amount} #{currency}"
               else
                 "[Guest] A contribution of #{amount} #{currency} was made"
               end,
      text: body_text
    )
  end
  handle_asynchronously :send_notification
end
