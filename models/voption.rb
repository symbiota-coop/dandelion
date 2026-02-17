class Voption
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :comment
  belongs_to_without_parent_validation :account

  field :text, type: String

  has_many :votes, dependent: :destroy

  validates_presence_of :text
end
