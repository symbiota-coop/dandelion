class Activityship
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :activity, index: true

  %w[admin unsubscribed hide_membership receive_feedback].each do |b|
    field b.to_sym, type: Boolean
    index({ b.to_s => 1 })
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
end
