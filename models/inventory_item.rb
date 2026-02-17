class InventoryItem
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :account, optional: true, class_name: 'Account', inverse_of: :inventory_items_listed
  belongs_to_without_parent_validation :responsible, optional: true, class_name: 'Account', inverse_of: :inventory_items_provided
  belongs_to_without_parent_validation :membership, optional: true
  belongs_to_without_parent_validation :team

  field :name, type: String
  field :description, type: String

  validates_presence_of :name, :gathering, :account, :membership

  before_validation do
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership
  end

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'created_inventory_item' if account
  end

  def circle
    gathering
  end

  def self.human_attribute_name(attr, options = {})
    {
      name: 'Item name'
    }[attr.to_sym] || super
  end
end
