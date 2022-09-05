class EventStar
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :event, index: true
  belongs_to :account, index: true

  validates_uniqueness_of :event, scope: :account

  def self.admin_fields
    {
      event_id: :lookup,
      account_id: :lookup
    }
  end
end
