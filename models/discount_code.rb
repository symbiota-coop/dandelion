class DiscountCode
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :codeable, polymorphic: true
  belongs_to_without_parent_validation :account, optional: true

  field :code, type: String
  field :description, type: String
  field :percentage_discount, type: Integer
  field :fixed_discount_amount, type: Float
  field :fixed_discount_currency, type: String
  field :filter, type: String
  field :maximum_uses, type: Integer

  validates_presence_of :code
  validates_uniqueness_of :code, scope: :codeable

  before_validation do
    errors.add(:percentage_discount, 'or fixed discount must be present') if !percentage_discount && !fixed_discount_amount
    errors.add(:percentage_discount, 'cannot be present if there is a fixed discount') if percentage_discount && fixed_discount_amount
    errors.add(:percentage_discount, 'must be positive') if percentage_discount && percentage_discount <= 0
    errors.add(:percentage_discount, 'must be less or equal to 100%') if percentage_discount && percentage_discount > 100
    errors.add(:fixed_discount_currency, 'must be present if there is a fixed discount amount') if fixed_discount_amount && !fixed_discount_currency
    errors.add(:fixed_discount_amount, 'must be positive') if fixed_discount_amount && fixed_discount_amount <= 0
    errors.add(:maximum_uses, 'must be at least 1, or blank for unlimited uses') if maximum_uses && maximum_uses < 1
  end


  before_validation do
    self.code = code.upcase if code
  end

  has_many :orders, dependent: :nullify

  def self.codeable_types
    %w[Organisation Activity LocalGroup Event]
  end

  def fixed_discount
    Money.new(fixed_discount_amount * 100, fixed_discount_currency) if fixed_discount_amount && fixed_discount_currency
  end

  def applies_to?(event)
    event.all_discount_codes.include?(self)
  end

  # The terms in filter: the code only applies to ticket types whose names contain one
  def filters
    filter ? filter.downcase.split(',').map(&:strip) : []
  end

  def applies_to_ticket_type?(ticket_type)
    !filter || filters.any? { |term| ticket_type.name.to_s.downcase.include?(term) }
  end

  # The orders that use up the code: paid ones, and unpaid ones still within Order::UNPAID_HOLD, so two buyers can't both
  # take its last use while paying. An unpaid order past the hold is abandoned (its Stripe session has expired, and the
  # hourly errands delete it), so it no longer counts; if it's paid after all, completing restores it and it counts again
  def uses
    orders.any_of({ payment_completed: true }, { :created_at.gte => Order::UNPAID_HOLD.ago })
  end

  def exhausted?(excluding: nil)
    return false unless maximum_uses

    used = uses
    used = used.and(:id.ne => excluding.id) if excluding&.persisted?
    used.count >= maximum_uses
  end

  def self.fixed_discount_currencies
    CURRENCY_OPTIONS
  end

  def self.new_hints
    {
      description: 'Private description, visible only to admins',
      maximum_uses: 'The maximum number of times this code can be used. Leave blank for unlimited uses',
      percentage_discount: 'The percentage discount to apply to the order e.g. 50 for 50%',
      fixed_discount_amount: 'The fixed discount to apply to the order e.g. 10 for £10',
      filter: 'Only apply the discount to ticket types where the name contains this term/these terms. Use commas to separate multiple terms'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end
end
