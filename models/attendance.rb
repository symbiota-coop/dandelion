class Attendance
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model

  belongs_to_without_parent_validation :tactivity
  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :membership

  def self.admin_fields
    {
      tactivity_id: :lookup,
      account_id: :lookup,
      gathering_id: :lookup,
      membership_id: :lookup
    }
  end

  before_validation do
    self.gathering = tactivity.gathering if tactivity
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership
  end

  validates_uniqueness_of :tactivity, scope: :account
end
