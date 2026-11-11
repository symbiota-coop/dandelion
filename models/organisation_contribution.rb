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
    Mailer.deliver(
      to: Account.and(admin: true),
      subject: "[Organisation] #{organisation.name} made a contribution of #{amount} #{currency}",
      text: "#{ENV['BASE_URI']}/o/#{organisation.slug}"
    )
  end
  handle_asynchronously :send_notification
end
