class Rslot
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :rota, index: true
  belongs_to :gathering, index: true

  field :name, type: String
  field :o, type: Integer

  def self.admin_fields
    {
      name: :text,
      o: :number,
      rota_id: :lookup,
      gathering_id: :lookup
    }
  end

  has_many :shifts, dependent: :destroy

  validates_presence_of :name, :o

  before_validation do
    self.gathering = rota.gathering if rota
    unless o
      max = rota.rslots.pluck(:o).compact.max
      self.o = max ? (max + 1) : 0
    end
  end
end
