class Cohostship
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :event, index: true
  belongs_to :organisation, index: true

  def self.admin_fields
    {
      event_id: :lookup,
      organisation_id: :lookup
    }
  end

  validates_uniqueness_of :event, scope: :organisation
end
