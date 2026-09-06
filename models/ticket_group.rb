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

  def slots_taken
    return tickets.and(made_available_at: nil).slots_taken unless event

    type_ids = event.ticket_types.select { |ticket_type| ticket_type.ticket_group_id == id }.map(&:id)
    event.ticket_counts.sum do |type_id, count|
      next 0 unless type_ids.include?(type_id)

      ticket_type = event.ticket_types.detect { |tt| tt.id == type_id }
      count * (ticket_type ? ticket_type.slots : 1)
    end
  end

  def places_remaining
    capacity - slots_taken
  end
end
