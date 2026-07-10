module RejectsActiveContent
  extend ActiveSupport::Concern

  EXTENSIONS = %w[.html .htm .xhtml .svg .svgz .xml .js].freeze

  included do
    validate :file_must_not_be_active_content
  end

  private

  def file_must_not_be_active_content
    return unless file

    errors.add(:file, 'type is not allowed') if EXTENSIONS.include?(File.extname(file.name.to_s).downcase)
  end
end
