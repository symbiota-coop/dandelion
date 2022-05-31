class TicketType
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :event, index: true
  belongs_to :ticket_group, optional: true, index: true

  field :name, type: String
  field :description, type: String
  field :price, type: Float
  field :quantity, type: Integer
  field :order, type: Integer
  field :hidden, type: Boolean
  field :max_quantity_per_transaction, type: Integer

  def self.admin_fields
    {
      name: :text,
      description: :text,
      price: :number,
      quantity: :number,
      order: :number,
      hidden: :check_box,
      max_quantity_per_transaction: :number,
      event_id: :lookup,
      tickets: :collection
    }
  end

  has_many :tickets, dependent: :nullify

  validates_presence_of :name, :price, :quantity

  before_validation do
    errors.add(:price, 'must not be not be < 0') if price && price < 0
    errors.add(:quantity, 'must not be not be < 0') if quantity && quantity < 0
    errors.add(:max_quantity_per_transaction, 'must not be not be < 0') if max_quantity_per_transaction && max_quantity_per_transaction < 0
  end

  def remaining
    (quantity || 0) - tickets.count
  end

  def wiser_remaining
    [remaining, ticket_group ? ticket_group.places_remaining : nil, event.places_remaining].compact.min
  end

  def number_of_tickets_available_in_single_purchase
    [remaining, ticket_group ? ticket_group.places_remaining : nil, event.places_remaining, max_quantity_per_transaction || nil].compact.min
  end
end
