class Stash
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :key, type: String
  field :value, type: String

  validates_presence_of :key, :value
  validates_uniqueness_of :key

  def self.admin_fields
    {
      key: { type: :text, full: true },
      value: :text_area
    }
  end
end
