class Carouselship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :carousel
  belongs_to_without_parent_validation :event_tag

  validates_uniqueness_of :event_tag, scope: :carousel

  after_create :refresh_parent_carousel_event_ids_cache
  after_destroy :refresh_parent_carousel_event_ids_cache

  def event_tag_name
    event_tag.name
  end

  def refresh_parent_carousel_event_ids_cache
    return unless carousel_id

    Carousel.find(carousel_id).refresh_event_ids_cache!
  end
end
