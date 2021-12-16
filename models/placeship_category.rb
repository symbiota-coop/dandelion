class PlaceshipCategory
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true

  field :name, type: String

  def self.admin_fields
    {
      name: :text,
      account_id: :lookup
    }
  end

  has_many :placeships, dependent: :nullify

  validates_presence_of :name
end
