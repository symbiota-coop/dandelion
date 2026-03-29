class EventBoostImpression
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event

  validates_presence_of :event
end
