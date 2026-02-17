class LocalGroupship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :local_group

  %w[admin unsubscribed hide_membership receive_feedback].each do |b|
    field b.to_sym, type: Boolean
  end

  validates_uniqueness_of :account, scope: :local_group

  def self.protected_attributes
    %w[admin]
  end

  after_create do
    account.account_notification_cache&.refresh_local_group_ids!
  end

  after_destroy do
    account.account_notification_cache&.refresh_local_group_ids!
  end
end
