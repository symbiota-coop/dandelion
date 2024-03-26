class Activityship
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true
  belongs_to :activity, index: true

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
