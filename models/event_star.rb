class EventStar
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :event, index: true
  belongs_to_without_parent_validation :account, index: true

  validates_uniqueness_of :event, scope: :account

  def self.admin_fields
    {
      event_id: :lookup,
      account_id: :lookup
    }
  end

  after_create do
    account.notifications_as_circle.create! notifiable: event, type: 'starred_event'
  end

  after_destroy do
    account.notifications_as_circle.find_by(notifiable_type: 'Event', notifiable_id: event.id, type: 'starred_event').try(:destroy)
  end
end
