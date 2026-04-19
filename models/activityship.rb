class Activityship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :activity

  %w[admin unsubscribed hide_membership receive_feedback].each do |b|
    field b.to_sym, type: Boolean
  end

  validates_uniqueness_of :account, scope: :activity

  before_create :set_hide_membership_for_closed_activity

  def self.protected_attributes
    %w[admin]
  end

  after_create do
    account.account_notification_cache&.refresh_activity_ids!
  end

  after_destroy do
    account.account_notification_cache&.refresh_activity_ids!
  end

  def set_hide_membership_for_closed_activity
    self.hide_membership = true if activity&.privacy == 'closed'
  end
end
