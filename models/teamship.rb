class Teamship
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :account, index: true
  belongs_to_without_parent_validation :team, index: true
  belongs_to_without_parent_validation :gathering, index: true
  belongs_to_without_parent_validation :membership, index: true

  field :unsubscribed, type: Boolean

  def self.admin_fields
    {
      account_id: :lookup,
      team_id: :lookup,
      gathering_id: :lookup,
      membership_id: :lookup,
      unsubscribed: :check_box
    }
  end

  validates_uniqueness_of :account, scope: :team

  after_create do
    team.posts.each { |post| post.subscriptions.create account: account }
  end

  before_validation do
    self.gathering = team.gathering if team
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership
  end

  attr_accessor :prevent_notifications

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'joined_team' unless prevent_notifications
  end

  def circle
    team.gathering
  end
end
