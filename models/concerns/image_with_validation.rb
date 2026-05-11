module ImageWithValidation
  extend ActiveSupport::Concern

  included do
    dragonfly_accessor :image do
      after_assign do |attachment|
        if attachment.image?
          if attachment.format != 'jpeg'
            attachment.convert('-format jpeg')
            attachment.name = "#{SecureRandom.uuid}.jpeg"
          end

          attachment.process!(:thumb, '1920x1920>')
        end
      end
    end

    before_save :set_warm_image_derivatives
    after_save :warm_image_derivatives, if: :warm_image_derivatives_after_save?
    handle_asynchronously :warm_image_derivatives

    before_validation :validate_image_format
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

  private

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

  def validate_image_format
    return unless image

    begin
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
