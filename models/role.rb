class Role
  include Mongoid::Document
  include Mongoid::Timestamps
  include DandelionMongo

  belongs_to_without_parent_validation :rota, index: true
  belongs_to_without_parent_validation :gathering, index: true

  field :name, type: String
  field :o, type: Integer
  field :worth, type: Float

  def self.admin_fields
    {
      name: :text,
      o: :number,
      worth: :number,
      rota_id: :lookup,
      gathering_id: :lookup
    }
  end

  before_validation do
    self.worth = 1 unless worth
  end

  has_many :shifts, dependent: :destroy

  validates_presence_of :name, :o

  before_validation do
    self.gathering = rota.gathering if rota
    unless o
      max = rota.roles.pluck(:o).compact.max
      self.o = max ? (max + 1) : 0
    end
  end
end
