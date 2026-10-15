module ImageWithValidation
  extend ActiveSupport::Concern

  MAX_IMAGE_BYTES = 20 * 1024 * 1024

  included do
    # Before dragonfly_accessor's own before_save, which then finds the image stored
    before_save :store_image

    dragonfly_accessor :image do
      after_assign do |attachment|
        image_span('assign') do
          if attachment.size.to_i > MAX_IMAGE_BYTES
            @image_too_large = true
            attachment.assign(nil)
          elsif attachment.image?
            if attachment.format != 'jpeg'
              attachment.convert('-format jpeg')
              attachment.name = "#{SecureRandom.uuid}.jpeg"
            end

            attachment.process!(:thumb, '1920x1920>')
          end
        end
      end
    end

    before_save :set_warm_image_derivatives
    after_save :warm_image_derivatives, if: :warm_image_derivatives_after_save?
    handle_asynchronously :warm_image_derivatives

    before_validation :validate_image_format
    before_validation :validate_image_size
    before_validation :set_has_image
  end

  class_methods do
    def prewarmed_image_derivative_sizes
      []
    end

    def prewarm_opengraph_image_derivative?
      false
    end
  end

  # Assigned in this request (an upload or image_url), or its uid set directly (a duplicated event's copied image)
  def image_new?
    image_changed? || image_uid_changed?
  end

  # Reading an image's width, height or format downloads the original from S3 and runs identify (about half a second
  # for a 1920px JPEG), so validations do it only for a new image, or one not measured yet
  def measure_image?
    image && (image_new? || !image_width_unmagic || !image_height_unmagic)
  end

  # ImageMagick (identify and convert) and S3 run outside Mongo and Net::HTTP, so they don't make spans of their own:
  # these show where an image upload's time goes in a trace
  def image_span(action, &)
    Sentry.with_child_span(op: "image.#{action}", description: "#{self.class.name} image", &)
  end

  private

  # Storing applies the processing assigning queued up (converting and resizing), then writes to S3
  def store_image
    return unless image_changed?

    image_span('store') { dragonfly_attachments[:image].save! }
  end

  def set_warm_image_derivatives
    @warm_image_derivatives_after_save = image.present? && image_changed?
    true
  end

  def warm_image_derivatives_after_save?
    @warm_image_derivatives_after_save
  end

  def warm_image_derivatives
    return unless image

    image_derivative_sizes.each { |size| image.thumb(size).url }
    image.encode('jpg', '-quality 90').thumb('1200x630').url if warm_opengraph_image_derivative?
  rescue StandardError, Dragonfly::Shell::CommandFailed => e
    ErrorReporting.capture_exception(e, context: { model: self.class.name, id: id.to_s })
  end

  def image_derivative_sizes
    self.class.prewarmed_image_derivative_sizes
  end

  def warm_opengraph_image_derivative?
    self.class.prewarm_opengraph_image_derivative?
  end

  def set_has_image
    self.has_image = image.present?
  end

  def validate_image_size
    errors.add(:image, 'must be smaller than 20 MB') if @image_too_large
  end

  def validate_image_format
    return unless image && image_new?

    image_span('validate') do
      if image.image?
        image.name = "#{SecureRandom.uuid}.#{image.format}"
      else
        errors.add(:image, 'must be an image')
      end
    rescue StandardError, Dragonfly::Shell::CommandFailed
      errors.add(:image, 'is not supported or corrupted')
    end
  end
end
