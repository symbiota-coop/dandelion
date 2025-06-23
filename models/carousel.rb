class Carousel
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :organisation, index: true

  field :name, type: String
  field :weeks, type: Integer
  field :o, type: Integer

  def self.admin_fields
    {
      organisation_id: :lookup,
      name: :text,
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

  has_many :carouselships, dependent: :destroy

  attr_accessor :tag_names

  before_validation do
    self.weeks = 8 unless weeks
  end

  def event_tags
    EventTag.and(:id.in => carouselships.pluck(:event_tag_id))
  end

  after_save :update_event_tags
  def update_event_tags
    @tag_names ||= ''
    @tag_names_a = @tag_names.split(',').map { |tag_name| tag_name.strip }
    current_tag_names = carouselships.map(&:event_tag_name)
    tags_to_remove = current_tag_names - @tag_names_a
    tags_to_add = @tag_names_a - current_tag_names
    tags_to_remove.each do |name|
      event_tag = EventTag.find_by(name: name)
      carouselships.find_by(event_tag: event_tag).destroy
    end
    tags_to_add.each do |name|
      if (event_tag = EventTag.find_or_create_by(name: name)).persisted?
        carouselships.create(event_tag: event_tag)
      end
    end
  end

  def events
    organisation.events_for_search.future_and_current.and(:start_time.lt => weeks.weeks.from_now).and(:hide_from_carousels.ne => true).and(:image_uid.ne => nil).and(:id.in => EventTagship.and(:event_tag_id.in => event_tags.pluck(:id)).pluck(:event_id)).limit(20) +
      organisation.events_for_search.past.and(:extra_info_for_recording_email.ne => nil).and(:hide_from_carousels.ne => true).and(:image_uid.ne => nil).and(:id.in => EventTagship.and(:event_tag_id.in => event_tags.pluck(:id)).pluck(:event_id)).limit(20)
  end
end
