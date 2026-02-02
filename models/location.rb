class Location
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :name, type: String
  field :query, type: String
  field :order, type: Integer

  validates_uniqueness_of :name

  def self.admin_fields
    {
      name: :text,
      query: :text,
      order: :number
    }
  end
end
