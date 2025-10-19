class Follow
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :follower, class_name: 'Account', inverse_of: :follows_as_follower, index: true
  belongs_to_without_parent_validation :followee, class_name: 'Account', inverse_of: :follows_as_followee, index: true

  %w[unsubscribed starred].each do |b|
    field b.to_sym, type: Boolean
  end

  def self.admin_fields
    {
      unsubscribed: :check_box,
      starred: :check_box,
      follower_id: :lookup,
      followee_id: :lookup
    }
  end

  validates_uniqueness_of :followee, scope: :follower
  before_validation do
    errors.add(:followee, 'cannot be the same as follower') if follower.id == followee.id
  end

  def self.mutual(alice, bob)
    Follow.find_by(follower: alice, followee: bob) && Follow.find_by(follower: bob, followee: alice)
  end

  has_many :notifications, as: :notifiable, dependent: :destroy

  after_create do
    follower.account_notification_cache&.invalidate!
  end

  after_destroy do
    follower.account_notification_cache&.invalidate!
  end
end
