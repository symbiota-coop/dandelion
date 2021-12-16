class Waitship
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

  after_create do
    event.organisation.organisationships.create account: account
    event.activity.activityships.create account: account if event.activity && event.activity.privacy == 'open'
    event.local_group.local_groupships.create account: account if event.local_group
  end
end
