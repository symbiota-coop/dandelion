class EventTagship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :event_tag

  validates_uniqueness_of :event_tag, scope: :event

  after_create do
    event&.sync_carousel_ids!
  end

  after_destroy do
    event&.sync_carousel_ids! unless event&.flagged_for_destroy?
  end

  def event_tag_name
    event_tag.name
  end
end
