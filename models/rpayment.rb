class Rpayment
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :event, index: true
  belongs_to :payer, class_name: 'Account', inverse_of: :rpayments_as_payer, index: true
  belongs_to :receiver, class_name: 'Account', inverse_of: :rpayments_as_receiver, index: true

  field :amount, type: Float
  field :currency, type: String
  field :role, type: String
  field :notes, type: String

  def self.roles
    Event.profit_share_roles
  end

  def self.admin_fields
    {
      event_id: :lookup,
      payer_id: :lookup,
      receiver_id: :lookup,
      amount: :number,
      currency: :text,
      role: :select,
      notes: :text_area
    }
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def amount_money
    Money.new amount * 100, currency
  end

  after_save do
    event.clear_cache if event
  end
  after_destroy do
    event.clear_cache if event
  end
end
