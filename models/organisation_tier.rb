class OrganisationTier
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :organisation, index: true

  field :name, type: String
  field :description, type: String
  field :threshold, type: Integer
  field :discount, type: Integer
  field :gc_plan_id, type: String

  def self.admin_fields
    {
      name: :text,
      description: :text_area,
      gc_plan_id: :text,
      threshold: :number,
      discount: :number,
      organisation_id: :lookup
    }
  end

  validates_presence_of :name, :threshold, :discount

  def self.human_attribute_name(attr, options = {})
    {
      gc_plan_id: 'GoCardless plan ID'
    }[attr.to_sym] || super
  end
end
