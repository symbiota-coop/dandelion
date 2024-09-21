module Geocoded
  extend ActiveSupport::Concern

  included do
    include Geocoder::Model::Mongoid
    geocoded_by :location
    def lat
      coordinates[1] if coordinates
    end

    def lng
      coordinates[0] if coordinates
    end
  end
end
