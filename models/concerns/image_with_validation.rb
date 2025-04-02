module ImageWithValidation
  extend ActiveSupport::Concern

  included do
    dragonfly_accessor :image do
      after_assign do |attachment|
        attachment.process!(:thumb, '1920x1920>') if attachment.image?
      end
    end

    before_validation :validate_image_format
  end

  private

  def validate_image_format
    return unless image

    begin
      if image.image?
        image.name = "#{SecureRandom.uuid}.#{image.format}"
      else
        errors.add(:image, 'must be an image')
      end
    rescue StandardError
      self.image = nil
      errors.add(:image, 'must be an image')
    end
  end
end
