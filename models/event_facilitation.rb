class EventFacilitation
  include Mongoid::Document
  include Mongoid::Timestamps
  include DandelionMongo

  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :event, index: true

  def self.admin_fields
    {
      account_id: :lookup,
      event_id: :lookup
    }
  end

  after_save :clear_cache
  after_destroy :clear_cache
  def clear_cache
    event.fragments.delete_all
  end

  validates_uniqueness_of :account, scope: :event
end
