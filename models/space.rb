class Space
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :timetable, index: true
  belongs_to :gathering, index: true

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

  dragonfly_accessor :image
  before_validation do
    if image
      begin
        image.format
      rescue StandardError
        self.image = nil
        errors.add(:image, 'must be an image')
      end
    end
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
