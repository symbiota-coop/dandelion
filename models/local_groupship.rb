class LocalGroupship
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true
  belongs_to :local_group, index: true

  %w[admin unsubscribed subscribed_discussion hide_membership].each do |b|
    field b.to_sym, type: Boolean; index({ b.to_s => 1 })
  end

  def self.admin_fields
    {
      account_id: :lookup,
      local_group_id: :lookup,
      unsubscribed: :check_box,
      subscribed_discussion: :check_box,
      hide_membership: :check_box,
      admin: :check_box
    }
  end

  validates_uniqueness_of :account, scope: :local_group

  def self.protected_attributes
    %w[admin]
  end
end
