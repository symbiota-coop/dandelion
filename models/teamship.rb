class Teamship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :team
  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :membership

  field :unsubscribed, type: Boolean

  def self.assignable_foreign_keys
    %w[account_id team_id]
  end

  validates_uniqueness_of :account, scope: :team

  after_create do
    team.posts.each { |post| post.subscriptions.create account: account }
  end

  before_validation do
    self.gathering = team.gathering if team && !gathering
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && membership&.account_id != account_id
  end

  validates_same_parent :team, via: :gathering

  attr_accessor :prevent_notifications

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'joined_team' unless prevent_notifications
  end

  def circle
    team.gathering
  end
end
