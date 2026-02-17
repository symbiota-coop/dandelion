class Vote
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :voption
  belongs_to_without_parent_validation :account

  validates_uniqueness_of :account, scope: :voption
end
