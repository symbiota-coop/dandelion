module HasFacebookPixel
  extend ActiveSupport::Concern

  included do
    field :facebook_pixel_id, type: String
    validates_format_of :facebook_pixel_id, with: /\A\d+\z/, allow_nil: true

    before_validation do
      self.facebook_pixel_id = facebook_pixel_id.strip if facebook_pixel_id
      self.facebook_pixel_id = nil if facebook_pixel_id.blank?
    end
  end
end
