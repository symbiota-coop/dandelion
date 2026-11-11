class LocalGroupship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include Subgroupship

  belongs_to_without_parent_validation :local_group

  validates_uniqueness_of :account, scope: :local_group

  def refresh_account_notification_cache
    account.account_notification_cache&.refresh_local_group_ids!
  end
end
