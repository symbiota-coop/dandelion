class EventStar
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :account

  validates_uniqueness_of :event, scope: :account

  def self.admin_fields
    {
      event_id: :lookup,
      account_id: :lookup
    }
  end

  after_create do
    account.notifications_as_circle.create!(notifiable: event, type: 'starred_event') if event.live? && event.public?
  end

  after_destroy do
    account.notifications_as_circle.find_by(notifiable_type: 'Event', notifiable_id: event.id, type: 'starred_event').try(:destroy)
  end
end
