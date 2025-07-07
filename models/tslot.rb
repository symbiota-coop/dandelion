class Tslot < DandelionModel
  belongs_to_without_parent_validation :timetable, index: true
  belongs_to_without_parent_validation :gathering, index: true

  field :name, type: String
  field :o, type: Integer

  def self.admin_fields
    {
      name: :text,
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
      max = timetable.tslots.pluck(:o).compact.max
      self.o = max ? (max + 1) : 0
    end
  end
end
