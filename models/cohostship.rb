class Cohostship
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :event, index: true
  belongs_to :organisation, index: true

  field :image_uid, type: String

  def self.admin_fields
    {
      image: :image,
      event_id: :lookup,
      organisation_id: :lookup
    }
  end

  before_validation do
    errors.add(:image, 'must be at least 800px wide') if image && image.width < 800
    errors.add(:image, 'must be more wide than high') if image && image.height > image.width

    begin
      self.image = image.encode('jpg') if image && !%w[jpg jpeg].include?(image.format)
    rescue StandardError
      self.image = nil
    end
  end

  dragonfly_accessor :image
  before_validation do
    if image
      begin
        image.format
      rescue StandardError
        self.image = nil
        errors.add(:image, 'must be an image')
      end
    end
  end

  validates_uniqueness_of :event, scope: :organisation
end
