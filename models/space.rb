class Space
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include ImageWithValidation

  belongs_to_without_parent_validation :timetable
  belongs_to_without_parent_validation :gathering

  field :name, type: String
  field :o, type: Integer
  field :image_uid, type: String
  field :has_image, type: Boolean

  has_many :tactivities

  # Its activities go back to Unscheduled, slot and all, rather than keeping a slot with no space
  before_destroy do
    tactivities.update_all(space_id: nil, tslot_id: nil)
  end

  validates_presence_of :name, :o

  before_validation do
    self.gathering = timetable.gathering if timetable
    unless o
      max = timetable.spaces.pluck(:o).compact.max
      self.o = max ? (max + 1) : 0
    end
  end
end
