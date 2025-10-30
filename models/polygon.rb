class Polygon
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :coordinates, type: Array
  field :type, type: String

  def self.admin_fields
    {
      coordinates: :text_area,
      type: :text
    }
  end

  before_validation do
    self.type = 'Polygon'
  end

  embedded_in :local_group

  # index({ coordinates: '2d' })
end
