class Carouselship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :carousel
  belongs_to_without_parent_validation :event_tag

  validates_uniqueness_of :event_tag, scope: :carousel

  after_create do
    tagged_events.each(&:sync_carousel_ids!)
  end

  after_destroy do
    tagged_events.each(&:sync_carousel_ids!) unless carousel&.flagged_for_destroy?
  end

  def tagged_events
    Event.and(:id.in => EventTagship.and(event_tag_id: event_tag_id).pluck(:event_id))
  end

  def event_tag_name
    event_tag.name
  end
end
