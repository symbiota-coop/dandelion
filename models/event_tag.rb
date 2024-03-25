class EventTag
  include Mongoid::Document
  include Mongoid::Timestamps

  field :name, type: String

  def self.admin_fields
    {
      name: { type: :text, full: true }
    }
  end

  validates_uniqueness_of :name

  has_many :event_tagships, dependent: :destroy

  before_validation do
    self.name = name.downcase if name
  end
end
