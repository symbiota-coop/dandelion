class TicketType
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :ticket_group, optional: true

  field :name, type: String
  field :description, type: String
  field :price, type: Float
  field :quantity, type: Integer
  field :order, type: Integer
  field :hidden, type: Boolean
  field :range_min, type: Float
  field :range_max, type: Float
  field :max_quantity_per_transaction, type: Integer
  field :minimum_monthly_donation, type: Float
  field :sales_end, type: Time

  attr_writer :price_or_range
  attr_accessor :price_or_range_submitted

  def price_or_range
    @price_or_range || (
      if range_min && range_max
        "#{range_min.to_i == range_min ? range_min.to_i : range_min}-#{range_max.to_i == range_max ? range_max.to_i : range_max}"
      end
    ) || (price.to_i == price ? price.to_i : price)
  end

  def self.admin_fields
    {
      name: :text,
      description: :text,
      price: :number,
      range_min: :number,
      range_max: :number,
      quantity: :number,
      order: :number,
      minimum_monthly_donation: :number,
      hidden: :check_box,
      max_quantity_per_transaction: :number,
      sales_end: :datetime,
      event_id: :lookup,
      tickets: :collection
    }
  end

  has_many :tickets, dependent: :nullify
  has_many :photos, as: :photoable, dependent: :destroy

  validates_presence_of :name, :quantity

  before_validation do
    if @price_or_range_submitted
      self.price = nil
      self.range_min = nil
      self.range_max = nil
      if @price_or_range
        if @price_or_range.to_s.include?('-')
          r_min, r_max = @price_or_range.to_s.split('-')
          self.range_min = r_min if floaty?(r_min)
          self.range_max = r_max if floaty?(r_max)
        elsif floaty?(@price_or_range)
          self.price = @price_or_range
        end
      end
    end

    errors.add(:range_min, 'must not be < 0') if range_min && range_min < 0
    errors.add(:range_max, 'must not be < 0') if range_max && range_max < 0
    errors.add(:range_max, 'must be > range min') if range_min && range_max && range_max <= range_min
    errors.add(:price, 'must not be < 0') if price && price < 0
    errors.add(:quantity, 'must not be < 0') if quantity && quantity < 0
    errors.add(:max_quantity_per_transaction, 'must not be < 0') if max_quantity_per_transaction && max_quantity_per_transaction < 0
  end

  after_save do
    if event
      event.refresh_sold_out_cache_and_notify_waitlist
    end
  end
  after_destroy do
    if event
      event.clear_cache
      event.set(sold_out_cache: event.sold_out?)
      event.set(sold_out_due_to_sales_end_cache: event.sold_out_due_to_sales_end?)
    end
  end

  def range
    range_min && range_max ? [range_min, range_max] : nil
  end

  def sales_ended?
    sales_end && Time.now > sales_end
  end

  def floaty?(obj)
    !Float(obj).nil?
  rescue StandardError
    false
  end

  def remaining
    (quantity || 0) - tickets.and(made_available_at: nil).count
  end

  def remaining_including_made_available
    (quantity || 0) - tickets.count
  end

  def wiser_remaining
    [remaining, ticket_group ? ticket_group.places_remaining : nil, event.places_remaining].compact.min
  end

  def number_of_tickets_available_in_single_purchase
    [remaining, ticket_group ? ticket_group.places_remaining : nil, event.places_remaining, max_quantity_per_transaction || nil].compact.min
  end
end
