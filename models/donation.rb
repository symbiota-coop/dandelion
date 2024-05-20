class Donation
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paranoia

  belongs_to :account, index: true
  belongs_to :event, index: true, optional: true
  belongs_to :order, index: true, optional: true

  field :amount, type: Float
  field :currency, type: String
  field :payment_completed, type: Boolean
  field :transferred, type: Boolean

  def incomplete?
    !payment_completed
  end

  def complete?
    payment_completed
  end

  def self.incomplete
    self.and(:payment_completed.ne => true)
  end

  def self.complete
    self.and(payment_completed: true)
  end

  def self.admin_fields
    {
      amount: :number,
      currency: :text,
      payment_completed: :check_box,
      account_id: :lookup,
      event_id: :lookup,
      order_id: :lookup
    }
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def self.email_viewer?(donation, account)
    account && Order.email_viewer?(donation.order, account)
  end

  validates_presence_of :amount

  before_validation do
    self.amount = amount.round(2)
    self.currency = order.try(:currency) || event.try(:currency)
    errors.add(:amount, 'minimum is 0.01') if amount < 0.01
    errors.add(:amount, 'is insufficient') if event.minimum_donation && amount < event.minimum_donation
  end

  def summary
    "#{event.name} : #{account.email}"
  end
end
