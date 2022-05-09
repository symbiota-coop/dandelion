class OrganisationTier
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :organisation, index: true

  field :name, type: String
  field :description, type: String
  field :threshold, type: Integer
  field :discount, type: Integer
  field :gocardless_url, type: String

  def self.admin_fields
    {
      name: :text,
      description: :text_area,
      gocardless_url: :url,
      threshold: :number,
      discount: :number,
      organisation_id: :lookup
    }
  end

  validates_presence_of :name, :threshold, :discount

  def self.human_attribute_name(attr, options = {})
    {
      gocardless_url: 'GoCardless URL'
    }[attr.to_sym] || super
  end
end
