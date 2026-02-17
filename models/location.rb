class Location
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :name, type: String
  field :query, type: String
  field :events_count, type: Integer
  field :signal_group_link, type: String

  validates_uniqueness_of :name

end
