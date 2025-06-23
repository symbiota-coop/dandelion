class Cohostship
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  include ImageWithValidation

  belongs_to :event, index: true
  belongs_to :organisation, index: true

  field :image_uid, type: String
  field :video_uid, type: String
  field :featured, type: Boolean
  index({ featured: 1 })

  def self.admin_fields
    {
      image: :image,
      video: :file,
      featured: :checkbox,
      event_id: :lookup,
      organisation_id: :lookup
    }
  end

  dragonfly_accessor :video

  before_validation do
    if image
      begin
        errors.add(:image, 'must be at least 992px wide') if image && image.width < 800 # legacy images are 800px
        errors.add(:image, 'must be more wide than high') if image && image.height > image.width
      rescue StandardError
        self.image = nil
      end
    end
  end

  validates_uniqueness_of :event, scope: :organisation
end
