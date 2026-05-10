class Waitship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :ticket_type, optional: true

  validates_uniqueness_of :account, scope: %i[event ticket_type]
  validate :ticket_type_belongs_to_event

  after_create do
    event.organisation.organisationships.create account: account
    event.activity.activityships.create account: account if event.activity && event.activity.privacy == 'open'
    event.local_group.local_groupships.create account: account if event.local_group
  end

  def ticket_type_belongs_to_event
    return unless ticket_type && event && ticket_type.event_id != event_id

    errors.add(:ticket_type, 'must belong to the event')
  end
end
