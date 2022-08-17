class Shift
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :role, index: true
  belongs_to :rslot, index: true
  belongs_to :rota, index: true
  belongs_to :gathering, index: true
  belongs_to :account, index: true, optional: true
  belongs_to :membership, index: true, optional: true

  def self.admin_fields
    {
      account_id: :lookup,
      role_id: :lookup,
      rslot_id: :lookup,
      rota_id: :lookup,
      gathering_id: :lookup,
      membership_id: :lookup
    }
  end

  validates_uniqueness_of :role, scope: :rslot

  before_validation do
    self.rota = role.rota if role
    self.gathering = rota.gathering if rota
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership
  end

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'signed_up_to_a_shift' if account
  end

  def worth
    (rslot.worth || 1) * (role.worth || 1)
  end

  def description
    "#{rota.name}: #{role.name}, #{rslot.name}"
  end

  def circle
    rota.gathering
  end
end
