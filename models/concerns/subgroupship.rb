# Membership of a subgroup of an organisation (Activityship, LocalGroupship). The model includes this after
# CoreExtensions, then names its subgroup (belongs_to and validates_uniqueness_of :account, scope: its subgroup)
# and defines refresh_account_notification_cache, which refreshes that subgroup's ids in the account's cache
module Subgroupship
  extend ActiveSupport::Concern

  included do
    belongs_to_without_parent_validation :account

    %w[admin unsubscribed hide_membership receive_feedback].each do |b|
      field b.to_sym, type: Mongoid::Boolean
    end

    after_create :refresh_account_notification_cache
    after_destroy :refresh_account_notification_cache
  end

  class_methods do
    def protected_attributes
      %w[admin]
    end
  end

  # Merging accounts (Account#merge): the victim's membership of the same subgroup goes with the victim
  def absorb_duplicate!(victim)
    set(admin: true) if victim.admin
    set(receive_feedback: true) if victim.receive_feedback
  end
end
