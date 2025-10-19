class Shift
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :role, index: true
  belongs_to_without_parent_validation :rslot, index: true
  belongs_to_without_parent_validation :rota, index: true
  belongs_to_without_parent_validation :gathering, index: true
  belongs_to_without_parent_validation :account, index: true, optional: true
  belongs_to_without_parent_validation :membership, index: true, optional: true

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

  validates_uniqueness_of :rslot, scope: :role

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
    rslot.worth * role.worth
  end

  def description
    "#{rota.name}: #{role.name}, #{rslot.name}"
  end

  def circle
    rota.gathering
  end

  def rslot_ids
    [''] + rota.rslots.map { |rslot| [rslot.name, rslot.id] }
  end

  def role_ids
    [''] + rota.roles.map { |role| [role.name, role.id] }
  end

  def self.human_attribute_name(attr, options = {})
    {
      rslot_id: 'Slot'
    }[attr.to_sym] || super
  end
end
