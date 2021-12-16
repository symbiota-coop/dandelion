class Polygon
  include Mongoid::Document
  include Mongoid::Timestamps

  field :coordinates, type: Array
  field :type, type: String

  before_validation do
    self.type = 'Polygon'
  end

  embedded_in :local_group

  index({ coordinates: '2d' })
end
