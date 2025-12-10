class AccountNotificationCache
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, index: true

  validates_uniqueness_of :account

  field :gathering_ids, type: Array, default: []
  field :account_ids, type: Array, default: []
  field :activity_ids, type: Array, default: []
  field :local_group_ids, type: Array, default: []
  field :organisations_ids, type: Array, default: []
  field :expires_at, type: Time

  def self.admin_fields
    {
      account_id: :lookup,
      gathering_ids: { type: :text_area, disabled: true },
      account_ids: { type: :text_area, disabled: true },
      activity_ids: { type: :text_area, disabled: true },
      local_group_ids: { type: :text_area, disabled: true },
      organisations_ids: { type: :text_area, disabled: true },
      expires_at: :datetime
    }
  end

  REFRESH_FIELD_MAPPINGS = {
    gathering_ids: ->(account) { account.memberships.pluck(:gathering_id) },
    account_ids: ->(account) { [account.id] + account.network_ids },
    activity_ids: ->(account) { account.activities_following_ids },
    local_group_ids: ->(account) { account.local_groups_following_ids },
    organisations_ids: ->(account) { account.organisations_following_ids }
  }.freeze

  def refresh!
    update_attributes(
      REFRESH_FIELD_MAPPINGS.transform_values { |proc| proc.call(account) }.merge(expires_at: 1.day.from_now)
    )
  end

  def cache_valid?
    expires_at && expires_at > Time.now
  end

  def invalidate!
    return if destroyed?

    set(expires_at: nil)
  end

  REFRESH_FIELD_MAPPINGS.each do |field_name, value_proc|
    define_method("refresh_#{field_name}!") do
      return if destroyed?

      set(
        field_name => value_proc.call(account),
        expires_at: 1.day.from_now
      )
    end
  end
end
