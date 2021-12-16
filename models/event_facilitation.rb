class EventFacilitation
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true
  belongs_to :event, index: true

  def self.admin_fields
    {
      account_id: :lookup,
      event_id: :lookup
    }
  end

  validates_uniqueness_of :account, scope: :event
end
