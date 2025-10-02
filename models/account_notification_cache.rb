class AccountNotificationCache
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :account, index: true

  validates_uniqueness_of :account

  field :gathering_ids, type: Array, default: []
  field :account_ids, type: Array, default: []
  field :activity_ids, type: Array, default: []
  field :local_group_ids, type: Array, default: []
  field :organisations_following_ids, type: Array, default: []
  field :organisations_monthly_donor_ids, type: Array, default: []
  field :expires_at, type: Time

  def self.admin_fields
    {
      account_id: :lookup,
      gathering_ids: { type: :text_area, disabled: true },
      account_ids: { type: :text_area, disabled: true },
      activity_ids: { type: :text_area, disabled: true },
      local_group_ids: { type: :text_area, disabled: true },
      organisations_following_ids: { type: :text_area, disabled: true },
      organisations_monthly_donor_ids: { type: :text_area, disabled: true },
      expires_at: :datetime
    }
  end

  def refresh!
    update_attributes(
      gathering_ids: account.memberships.pluck(:gathering_id),
      account_ids: [account.id] + account.network.pluck(:id),
      activity_ids: account.activities_following.pluck(:id),
      local_group_ids: account.local_groups_following.pluck(:id),
      organisations_following_ids: account.organisations_following.pluck(:id),
      organisations_monthly_donor_ids: account.organisations_monthly_donor.pluck(:id),
      expires_at: 1.day.from_now
    )
  end

  def cache_valid?
    expires_at && expires_at > Time.now
  end

  def invalidate!
    update_attribute(:expires_at, nil)
  end
end
