class EventFacilitation
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :event

  after_save :clear_cache
  after_destroy :clear_cache
  def clear_cache
    event.fragments.delete_all
  end

  validates_uniqueness_of :account, scope: :event
end
