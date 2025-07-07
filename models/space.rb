class Space
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  extend Dragonfly::Model
  include ImageWithValidation

  belongs_to_without_parent_validation :timetable, index: true
  belongs_to_without_parent_validation :gathering, index: true

  field :name, type: String
  field :o, type: Integer
  field :image_uid, type: String

  def self.admin_fields
    {
      name: :text,
      image: :image,
      o: :number,
      timetable_id: :lookup,
      gathering_id: :lookup
    }
  end

  has_many :tactivities, dependent: :nullify

  validates_presence_of :name, :o

  before_validation do
    self.gathering = timetable.gathering if timetable
    unless o
      max = timetable.spaces.pluck(:o).compact.max
      self.o = max ? (max + 1) : 0
    end
  end
end
