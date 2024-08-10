class OrganisationContribution
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :organisation, index: true

  field :amount, type: Float
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
      organisation_id: :lookup,
      currency: :text,
      amount: :number
    }
  end

  validates_presence_of :amount, :currency

  after_save do
    organisation.update_paid_up
  end

  after_destroy do
    organisation.update_paid_up
  end

  def send_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "[Organisation] #{organisation.name} made a contribution of #{amount} #{currency}"
    batch_message.body_text "#{ENV['BASE_URI']}/o/#{organisation.slug}"

    Account.and(admin: true).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_notification
end
