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
      description: 'Private description, visible only to admins',
      maximum_uses: 'The maximum number of times this code can be used',
      percentage_discount: 'The percentage discount to apply to the order e.g. 50 for 50%',
      fixed_discount_amount: 'The fixed discount to apply to the order e.g. 10 for £10',
      filter: 'Only apply the discount to ticket types where the name contains this term/these terms. Use commas to separate multiple terms'
    }
  end

  def self.edit_hints
    {}.merge(new_hints)
  end
end
