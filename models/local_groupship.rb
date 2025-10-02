class LocalGroupship
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :local_group, index: true

  %w[admin unsubscribed hide_membership receive_feedback].each do |b|
    field b.to_sym, type: Boolean
  end

  def self.admin_fields
    {
      account_id: :lookup,
      local_group_id: :lookup,
      unsubscribed: :check_box,
      hide_membership: :check_box,
      admin: :check_box
    }
  end

  validates_uniqueness_of :account, scope: :local_group

  def self.protected_attributes
    %w[admin]
  end

  after_create do
    account.account_notification_cache&.invalidate!
  end

  after_destroy do
    account.account_notification_cache&.invalidate!
  end
end
