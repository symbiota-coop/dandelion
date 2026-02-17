class Stash
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :key, type: String
  field :value, type: String

  validates_presence_of :key, :value
  validates_uniqueness_of :key

end
