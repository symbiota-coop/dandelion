class Payment
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :gathering, index: true
  belongs_to_without_parent_validation :membership, index: true

  field :gathering_name, type: String
  field :amount, type: Integer
  field :currency, type: String
  field :session_id, type: String
  field :payment_intent, type: String
  field :coinbase_checkout_id, type: String
  field :evm_secret, type: String
  field :evm_amount, type: BigDecimal
  field :payment_completed, type: Boolean

  def self.admin_fields
    {
      account_id: :lookup,
      gathering_id: :lookup,
      membership_id: :lookup,
      gathering_name: :text,
      currency: :text,
      amount: :number,
      session_id: :text,
      payment_intent: :text,
      coinbase_checkout_id: :text,
      evm_secret: :text,
      evm_amount: :number,
      payment_completed: :check_box
    }
  end

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'created_payment' unless gathering.hide_paid || gathering.options.any?(&:hide_members)
  end

  def circle
    gathering
  end

  validates_presence_of :gathering_name, :amount, :currency
  validates_uniqueness_of :evm_secret, scope: :evm_amount, allow_nil: true

  def evm_offset
    evm_secret.to_d / 1e6
  end

  before_validation do
    self.account = membership.account if membership
    self.gathering = membership.gathering if membership
    self.gathering_name = gathering.name if gathering

    self.evm_amount = amount.to_d + evm_offset if evm_secret && !evm_amount
  end

  def payment_completed!
    set(payment_completed: true)
    membership.set(paid: membership.paid + amount)
    gathering.set(processed_via_dandelion: gathering.processed_via_dandelion + amount)
    gathering.set(balance: gathering.balance + amount)
  end

  def update_metadata
    return unless payment_intent

    Stripe.api_key = gathering.stripe_sk
    Stripe.api_version = '2020-08-27'
    pi = Stripe::PaymentIntent.retrieve payment_intent
    charge = Stripe::Charge.retrieve pi.charges.first.id
    Stripe::Charge.update(charge.id, { metadata: {
                            de_gathering_id: gathering.id,
                            de_account_id: account.id
                          } })
  rescue StandardError => e
    Honeybadger.notify(e)
  end
end
