module HasFacebookPixel
  extend ActiveSupport::Concern

  included do
    field :facebook_pixel_id, type: String
    validates_format_of :facebook_pixel_id, with: /\A\d+\z/, allow_nil: true

    before_validation do
      self.facebook_pixel_id = facebook_pixel_id.strip.presence if facebook_pixel_id
    end
  end
end
