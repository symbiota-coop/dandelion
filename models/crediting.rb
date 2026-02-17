class Crediting
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :organisationship

  field :amount, type: Integer
  field :currency, type: String


  validates_presence_of :amount, :currency

  def self.currencies
    CURRENCY_OPTIONS
  end
end
