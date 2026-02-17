class Tslot
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :timetable
  belongs_to_without_parent_validation :gathering

  field :name, type: String
  field :o, type: Integer

  has_many :tactivities, dependent: :nullify

  validates_presence_of :name, :o

  before_validation do
    self.gathering = timetable.gathering if timetable
    unless o
      max = timetable.tslots.pluck(:o).compact.max
      self.o = max ? (max + 1) : 0
    end
  end
end
