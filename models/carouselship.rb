class Carouselship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :carousel
  belongs_to_without_parent_validation :event_tag

  validates_uniqueness_of :event_tag, scope: :carousel

  def event_tag_name
    event_tag.name
  end
end
