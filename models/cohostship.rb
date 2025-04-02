class Cohostship
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  include ImageWithValidation

  belongs_to :event, index: true
  belongs_to :organisation, index: true

  field :image_uid, type: String
  field :video_uid, type: String

  def self.admin_fields
    {
      image: :image,
      video: :file,
      event_id: :lookup,
      organisation_id: :lookup
    }
  end

  dragonfly_accessor :video

  before_validation do
    if image

      begin
        self.image = image.encode('jpg') if image && !%w[jpg jpeg].include?(image.format)
      rescue StandardError
        self.image = nil
      end

      errors.add(:image, 'must be at least 992px wide') if image && image.width < 800 # legacy images are 800px
      errors.add(:image, 'must be more wide than high') if image && image.height > image.width

    end
  end

  validates_uniqueness_of :event, scope: :organisation
end
