class Carouselship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :carousel
  belongs_to_without_parent_validation :event_tag

  validates_uniqueness_of :event_tag, scope: :carousel

  after_create do
    carousel.sync_tagged_event_carousel_ids(event_tag_id)
  end

  after_destroy do
    carousel.sync_tagged_event_carousel_ids(event_tag_id) unless carousel&.flagged_for_destroy?
  end

  def event_tag_name
    event_tag.name
  end
end
