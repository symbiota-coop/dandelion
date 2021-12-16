class PaymentAttempt
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true
  belongs_to :gathering, index: true
  belongs_to :membership, index: true
  # has_one :payment_attempt, :dependent => :nullify

  field :gathering_name, type: String
  field :amount, type: Integer
  field :currency, type: String
  field :session_id, type: String
  field :payment_intent, type: String
  field :coinbase_checkout_id, type: String
  field :seeds_secret, type: String
  field :seeds_amount, type: Float
  field :xdai_secret, type: String
  field :xdai_amount, type: BigDecimal

  def self.admin_fields
    {
      session_id: :text,
      payment_intent: :text,
      coinbase_checkout_id: :text,
      account_id: :lookup,
      gathering_id: :lookup,
      membership_id: :lookup,
      gathering_name: :text,
      currency: :text,
      amount: :number
    }
  end

  validates_presence_of :gathering_name, :amount, :currency
  validates_uniqueness_of :seeds_secret, scope: :seeds_amount, allow_nil: true
  validates_uniqueness_of :xdai_secret, scope: :xdai_amount, allow_nil: true

  before_validation do
    self.account = membership.account if membership
    self.gathering = membership.gathering if membership
    self.gathering_name = gathering.name if gathering

    self.xdai_amount = amount.to_d + xdai_secret.to_i(36).to_d / 1e15.to_d if xdai_secret && !xdai_amount
    self.seeds_amount = amount if seeds_secret && !seeds_amount
  end
end
