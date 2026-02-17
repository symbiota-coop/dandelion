class Rota
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :account

  field :name, type: String
  field :description, type: String

  validates_presence_of :name, :gathering

  has_many :roles, dependent: :destroy
  has_many :rslots, dependent: :destroy
  has_many :shifts, dependent: :destroy

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'created_rota'
  end

  def circle
    gathering
  end
end
