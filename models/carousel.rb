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

  validates_presence_of :name

  def self.admin_fields
    {
      organisation_id: :lookup,
      name: :text,
      hidden: :check_box,
      button: :check_box,
      weeks: :number,
      o: :number,
      carouselships: :collection
    }
  end

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

  before_validation do
    self.weeks = 8 unless weeks
  end

  def event_tags
    EventTag.and(:id.in => carouselships.pluck(:event_tag_id))
  end

  def event_tag_ids
    carouselships.pluck(:event_tag_id)
  end

  def events(minimal: false)
    future_events = organisation.events_including_cohosted.live.publicly_visible.future_and_current.and(:start_time.lt => weeks.weeks.from_now).and(hide_from_carousels: false).and(has_image: true).and(:id.in => EventTagship.and(:event_tag_id.in => event_tag_ids).pluck(:event_id))
    past_events = organisation.events_including_cohosted.live.publicly_visible.past.and(has_recording: true).and(hide_from_carousels: false).and(has_image: true).and(:id.in => EventTagship.and(:event_tag_id.in => event_tag_ids).pluck(:event_id))

    unless minimal
      future_events = future_events.and(minimal_only: false)
      past_events = past_events.and(minimal_only: false)
    end

    (future_events.limit(20) + past_events.limit(20)).uniq
  end
end
