class Rpayment
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :account

  field :amount, type: Float
  field :currency, type: String
  field :role, type: String
  field :notes, type: String

  validates_presence_of :amount, :currency, :role

  def self.roles
    Event.profit_share_roles
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
