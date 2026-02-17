class Fragment
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event, optional: true

  field :key, type: String
  field :value, type: String
  field :expires, type: Time

  validates_presence_of :key, :value, :expires
  validates_uniqueness_of :key

end
