class Withdrawal
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :gathering, index: true

  field :gathering_name, type: String
  field :amount, type: Float
  field :currency, type: String

  def self.admin_fields
    {
      gathering_id: :lookup,
      gathering_name: { type: :text, disabled: true },
      currency: { type: :text, disabled: true },
      amount: :number
    }
  end

  validates_presence_of :gathering_name, :amount, :currency

  before_validation do
    self.gathering_name = gathering.name if gathering
    self.currency = gathering.currency if gathering
  end

  after_create do
    gathering.update_attribute(:balance, gathering.balance - amount)
  end
end
