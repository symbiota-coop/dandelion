class OrganisationContribution
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :organisation

  field :amount, type: Float
  field :currency, type: String
  field :session_id, type: String
  field :payment_intent, type: String
  field :coinbase_checkout_id, type: String
  field :payment_completed, type: Boolean

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

    batch_message.finalize if Padrino.env == :production
  end
  handle_asynchronously :send_notification
end
