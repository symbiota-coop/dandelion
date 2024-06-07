class DiscountCode
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :codeable, polymorphic: true, index: true
  belongs_to :account, optional: true, index: true

  field :code, type: String
  field :description, type: String
  field :percentage_discount, type: Integer
  field :filter, type: String

  validates_presence_of :code
  validates_presence_of :percentage_discount # for the time being
  validates_uniqueness_of :code, scope: :codeable

  before_validation do
    errors.add(:percentage_discount, 'must be positive') if percentage_discount <= 0
    errors.add(:percentage_discount, 'must be less or equal to 99%') if percentage_discount > 99
  end

  def self.admin_fields
    {
      code: :text,
      description: :text,
      filter: :text,
      percentage_discount: :number,
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

  def applies_to?(event)
    event.all_discount_codes.include?(self)
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
