class OrganisationContribution
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :organisation, index: true

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
      organisation_id: :lookup,
      currency: :text,
      amount: :number
    }
  end

  validates_presence_of :amount, :currency
end
