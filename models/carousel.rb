class Carousel
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include Taggable

  taggable tagships: :carouselships, tag_class: EventTag

  belongs_to_without_parent_validation :organisation

  field :name, type: String
  field :weeks, type: Integer
  field :o, type: Integer
  field :hidden, type: Boolean
  field :button, type: Boolean
  field :event_ids_cache, type: Array

  validates_presence_of :name

  def self.new_hints
    {
      weeks: 'Show events up to this many weeks from now'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end

  def self.human_attribute_name(attr, options = {})
    {
      button: 'Show button',
      hidden: 'Hide carousel'
    }[attr] || super
  end

  def self.invalidate_event_ids_cache_for_event_tag_id(event_tag_id)
    return if event_tag_id.blank?

    carousel_ids = Carouselship.and(event_tag_id: event_tag_id).only(:carousel_id).pluck(:carousel_id).compact.uniq
    Carousel.and(:id.in => carousel_ids).find_each(&:refresh_event_ids_cache!) if carousel_ids.any?
  end

  def self.event_ids_for_carousel_ids(carousel_ids)
    carousel_ids = Array(carousel_ids)
    return [] if carousel_ids.empty?

    Carousel.and(:id.in => carousel_ids).only(:event_ids_cache).pluck(:event_ids_cache).flatten.compact.uniq
  end

  def refresh_event_ids_cache!
    ids = event_ids_for_tags.uniq
    set(event_ids_cache: ids)
    ids
  end

  has_many :carouselships, dependent: :destroy
  has_many_through :event_tags, through: :carouselships

  before_validation do
    self.weeks = 8 unless weeks
  end

  after_create :refresh_event_ids_cache!

  def event_ids_for_tags
    EventTagship.and(:event_tag_id.in => event_tag_ids).pluck(:event_id)
  end

  def events(minimal: false)
    eids = event_ids_cache
    future_events = organisation.events_including_cohosted.live.publicly_visible.future_and_current.and(:start_time.lt => weeks.weeks.from_now).and(hide_from_carousels: false).and(has_image: true).and(:id.in => eids)
    past_events = organisation.events_including_cohosted.live.publicly_visible.past.and(has_recording: true).and(hide_from_carousels: false).and(has_image: true).and(:id.in => eids)

    unless minimal
      future_events = future_events.and(minimal_only: false)
      past_events = past_events.and(minimal_only: false)
    end

    (future_events.limit(20) + past_events.limit(20)).uniq
  end
end
