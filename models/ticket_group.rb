class TicketGroup
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event

  field :name, type: String
  field :capacity, type: Integer

  has_many :ticket_types, dependent: :nullify

  def tickets
    Ticket.and(:ticket_type_id.in => ticket_types.pluck(:id))
  end

  validates_presence_of :name, :capacity

  before_validation do
    errors.add(:capacity, 'must not be < 0') if capacity && capacity < 0
  end

  def places_remaining
    capacity - tickets.count
  end
end
