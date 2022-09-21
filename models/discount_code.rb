class DiscountCode
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :codeable, polymorphic: true, index: true
  belongs_to :account, optional: true, index: true

  field :code, type: String
  field :description, type: String
  field :fixed_discount, type: Integer
  field :percentage_discount, type: Integer

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
      fixed_discount: :number,
      percentage_discount: :number,
      codeable_type: :select,
      codeable_id: :text,
      account_id: :lookup
    }
  end

  has_many :orders, dependent: :nullify

  def self.codeable_types
    %w[Organisation Activity LocalGroup Event]
  end

  def applies_to?(event)
    event.all_discount_codes.include?(self)
  end
end
