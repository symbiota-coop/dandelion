module ImageWithValidation
  extend ActiveSupport::Concern

  included do
    dragonfly_accessor :image do
      after_assign do |attachment|
        if attachment.image? && valid_image_format?(attachment)
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

  def valid_image_format?(attachment)
    return false unless attachment

    # Check file extension
    valid_extensions = %w[jpg jpeg png gif bmp webp heic heif tiff tif]
    extension = attachment.name&.split('.')&.last&.downcase
    return false unless valid_extensions.include?(extension)

    # Check MIME type if available
    if attachment.respond_to?(:mime_type) && attachment.mime_type
      return attachment.mime_type.start_with?('image/')
    end

    true
  rescue StandardError
    false
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
