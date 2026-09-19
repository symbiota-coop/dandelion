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

  def self.protected_attributes
    %w[organisation_id]
  end

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

  has_many :carouselships, dependent: :destroy
  has_many_through :event_tags, through: :carouselships

  after_destroy do
    Event.collection.update_many(
      { 'deleted_at' => nil, 'carousel_ids' => id },
      { '$pull' => { 'carousel_ids' => id } }
    )
  end

  before_validation do
    self.weeks = 8 unless weeks
  end

  def sync_tagged_event_carousel_ids(event_tag_id)
    return unless organisation && event_tag_id

    event_ids = EventTagship.and(event_tag_id: event_tag_id).pluck(:event_id)
    return if event_ids.empty?

    organisation.events_including_cohosted.and(:id.in => event_ids).each(&:sync_carousel_ids!)
  end
  handle_asynchronously :sync_tagged_event_carousel_ids

  def events(minimal: false)
    future_events = organisation.events_including_cohosted.live.publicly_visible.future_current_evergreen.and(:start_time.lt => weeks.weeks.from_now).and(hide_from_carousels: false).and(has_image: true).and(carousel_ids: id)
    past_events = organisation.events_including_cohosted.live.publicly_visible.past.and(has_recording: true).and(hide_from_carousels: false).and(has_image: true).and(carousel_ids: id)

    unless minimal
      future_events = future_events.and(minimal_only: false)
      past_events = past_events.and(minimal_only: false)
    end

    (future_events.limit(20) + past_events.limit(20)).uniq
  end
end
