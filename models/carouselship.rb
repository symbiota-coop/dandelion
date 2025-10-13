class Carouselship
  include Mongoid::Document
  include Mongoid::Timestamps
  include DandelionMongo

  belongs_to_without_parent_validation :carousel, index: true
  belongs_to_without_parent_validation :event_tag, index: true

  def self.admin_fields
    {
      carousel_id: :lookup,
      event_tag_id: :lookup
    }
  end

  validates_uniqueness_of :event_tag, scope: :carousel

  def event_tag_name
    event_tag.name
  end
end
