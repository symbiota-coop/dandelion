class Activityship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include Subgroupship

  belongs_to_without_parent_validation :activity

  validates_uniqueness_of :account, scope: :activity

  before_create :set_hide_membership_for_closed_activity

  def refresh_account_notification_cache
    account.account_notification_cache&.refresh_activity_ids!
  end

  def set_hide_membership_for_closed_activity
    self.hide_membership = true if activity&.privacy == 'closed'
  end
end
