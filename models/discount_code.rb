class DiscountCode
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :codeable, polymorphic: true, index: true
  belongs_to :account, optional: true, index: true

  field :code, type: String
  field :description, type: String
  field :percentage_discount, type: Integer
  field :fixed_discount_amount, type: Float
  field :fixed_discount_currency, type: String
  field :filter, type: String

  validates_presence_of :code
  validates_uniqueness_of :code, scope: :codeable

  before_validation do
    errors.add(:percentage_discount, 'or fixed discount must be present') if !percentage_discount && !fixed_discount_amount
    errors.add(:percentage_discount, 'cannot be present if there is a fixed discount') if percentage_discount && fixed_discount_amount
    errors.add(:fixed_discount_currency, 'must be present if there is a fixed discount amount') if fixed_discount_amount && !fixed_discount_currency
    errors.add(:percentage_discount, 'must be positive') if percentage_discount && percentage_discount <= 0
    errors.add(:percentage_discount, 'must be less or equal to 100%') if percentage_discount && percentage_discount > 100
  end

  def self.admin_fields
    {
      code: :text,
      description: :text,
      filter: :text,
      percentage_discount: :number,
      fixed_discount_amount: :number,
      fixed_discount_currency: :select,
      codeable_type: :select,
      codeable_id: :text,
      account_id: :lookup
    }
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

  def self.fixed_discount_currencies
    CURRENCY_OPTIONS
  end

  def self.new_hints
    {
      filter: 'Only apply the discount to tickets containing this term'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end
end
