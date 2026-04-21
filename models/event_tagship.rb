class EventTagship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :event_tag

  validates_uniqueness_of :event_tag, scope: :event

  after_create :invalidate_carousel_event_ids_caches_for_event_tag
  after_destroy :invalidate_carousel_event_ids_caches_for_event_tag

  def event_tag_name
    event_tag.name
  end

  def invalidate_carousel_event_ids_caches_for_event_tag
    Carousel.invalidate_event_ids_cache_for_event_tag_id(event_tag_id)
  end
end
