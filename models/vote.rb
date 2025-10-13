class Vote
  include Mongoid::Document
  include Mongoid::Timestamps
  include DandelionMongo

  belongs_to_without_parent_validation :voption, index: true
  belongs_to_without_parent_validation :account, index: true

  def self.admin_fields
    {
      voption_id: :lookup,
      account_id: :lookup
    }
  end

  validates_uniqueness_of :account, scope: :voption
end
