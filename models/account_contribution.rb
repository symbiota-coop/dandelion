class AccountContribution
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true

  field :amount, type: Integer
  field :currency, type: String
  field :session_id, type: String
  field :payment_intent, type: String
  field :coinbase_checkout_id, type: String
  field :payment_completed, type: Boolean

  def self.admin_fields
    {
      session_id: :text,
      payment_intent: :text,
      coinbase_checkout_id: :text,
      payment_completed: :check_box,
      account_id: :lookup,
      currency: :text,
      amount: :number
    }
  end

  validates_presence_of :amount, :currency

  def send_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject "[Account] #{account.name} made a contribution of #{amount} #{currency}"

    Account.and(admin: true).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_notification
end
