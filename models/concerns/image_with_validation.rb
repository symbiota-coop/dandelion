module ImageWithValidation
  extend ActiveSupport::Concern

  included do
    dragonfly_accessor :image do
      after_assign do |attachment|
        if attachment.image?
          if attachment.format == 'heic'
            attachment.convert('-format jpeg')
            attachment.name = "#{SecureRandom.uuid}.jpg"
          end

          attachment.process!(:thumb, '1920x1920>')
        end
      end
    end

    before_validation :validate_image_format
    before_validation :set_has_image
  end

  private

  def set_has_image
    self.has_image = image.present?
  end

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
