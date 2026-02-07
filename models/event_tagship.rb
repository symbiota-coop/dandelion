class EventTagship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :event_tag

  def self.admin_fields
    {
      event_id: :lookup,
      event_tag_id: :lookup
    }
  end

  validates_uniqueness_of :event_tag, scope: :event

  def event_tag_name
    event_tag.name
  end
end
