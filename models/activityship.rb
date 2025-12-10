class Activityship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :activity, index: true

  %w[admin unsubscribed hide_membership receive_feedback].each do |b|
    field b.to_sym, type: Boolean
  end

  def self.admin_fields
    {
      account_id: :lookup,
      activity_id: :lookup,
      unsubscribed: :check_box,
      hide_membership: :check_box,
      admin: :check_box
    }
  end

  validates_uniqueness_of :account, scope: :activity

  def self.protected_attributes
    %w[admin]
  end

  after_create do
    account.account_notification_cache&.refresh_activity_ids!
  end

  after_destroy do
    account.account_notification_cache&.refresh_activity_ids!
  end
end
