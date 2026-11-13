class Payment
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :membership

  field :gathering_name, type: String
  field :amount, type: Integer
  field :currency, type: String
  field :session_id, type: String
  field :payment_intent, type: String
  field :coinbase_checkout_id, type: String
  field :evm_secret, type: String
  field :evm_amount, type: BigDecimal
  field :payment_completed, type: Boolean

  has_many :notifications, as: :notifiable, dependent: :destroy

  def circle
    gathering
  end

  validates_presence_of :gathering_name, :amount, :currency
  validates_uniqueness_of :evm_secret, scope: :evm_amount, allow_nil: true

  def self.protected_attributes
    %w[payment_completed]
  end

  def evm_offset
    evm_secret.to_d / 1e6
  end

  before_validation do
    self.account = membership.account if membership
    self.gathering = membership.gathering if membership
    self.gathering_name = gathering.name if gathering

    self.evm_amount = amount.to_d + evm_offset if evm_secret && !evm_amount
  end

  # Claims the payment atomically, so two callers at once (two deliveries of Stripe's webhook, or a poll checking the
  # EVM account) credit the membership only once
  def payment_completed!
    return unless Payment.collection.find_one_and_update({ _id: id, payment_completed: { '$ne' => true } }, { '$set' => { payment_completed: true } })

    attributes['payment_completed'] = true
    membership.inc(paid: amount)
    gathering.inc(processed_via_dandelion: amount, balance: amount)
    notifications.create! circle: circle, type: 'created_payment' unless gathering.hide_paid || gathering.options.any?(&:hide_members)
  end
end
