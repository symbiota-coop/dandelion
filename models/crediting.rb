class Crediting
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model

  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :organisationship, index: true

  field :amount, type: Integer
  field :currency, type: String

  def self.admin_fields
    {
      amount: :number,
      currency: :select,
      account_id: :lookup,
      organisationship_id: :lookup
    }
  end

  validates_presence_of :amount, :currency

  def self.currencies
    CURRENCY_OPTIONS
  end
end
