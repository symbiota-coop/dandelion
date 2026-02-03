class Location
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :name, type: String
  field :query, type: String
  field :events_count, type: Integer

  validates_uniqueness_of :name

  def self.admin_fields
    {
      name: :text,
      query: :text,
      events_count: :number
    }
  end
end
