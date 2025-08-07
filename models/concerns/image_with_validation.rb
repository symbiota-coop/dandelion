module ImageWithValidation
  extend ActiveSupport::Concern

  included do
    dragonfly_accessor :image do
      after_assign do |attachment|
        if attachment.image? && valid_image_format?(attachment.format)
          if attachment.format == 'heic'
            attachment.convert('-format jpeg')
            attachment.name = "#{SecureRandom.uuid}.jpg"
          end

          attachment.process!(:thumb, '1920x1920>')
        end
      end
    end

    before_validation :validate_image_format
  end

  private

  def valid_image_format?(format)
    return false unless format
    
    valid_formats = %w[jpg jpeg png gif bmp webp heic heif tiff tif]
    valid_formats.include?(format.to_s.downcase)
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
