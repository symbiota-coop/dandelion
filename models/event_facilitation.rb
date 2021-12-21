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

  after_save :clear_cache
  after_destroy :clear_cache
  def clear_cache
    Fragment.and(key: %r{/events/#{event_id}}).destroy_all
  end

  validates_uniqueness_of :account, scope: :event
end
