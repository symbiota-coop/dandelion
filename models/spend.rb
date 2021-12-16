class Spend
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :team, index: true
  belongs_to :gathering, index: true
  belongs_to :account, index: true
  belongs_to :membership, index: true

  field :item, type: String
  field :amount, type: Integer
  field :reimbursed, type: Boolean

  def self.admin_fields
    {
      item: :text,
      amount: :number,
      team_id: :lookup,
      reimbursed: :check_box,
      gathering_id: :lookup,
      account_id: :lookup,
      membership_id: :lookup
    }
  end

  validates_presence_of :item, :amount

  before_validation do
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership
  end

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'created_spend'
  end

  def circle
    gathering
  end

  def self.human_attribute_name(attr, options = {})
    {
      amount: 'Cost',
      account_id: 'Paid by'
    }[attr.to_sym] || super
  end
end
