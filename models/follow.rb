class Follow
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :follower, class_name: 'Account', inverse_of: :follows_as_follower, index: true
  belongs_to :followee, class_name: 'Account', inverse_of: :follows_as_followee, index: true

  %w[unsubscribed starred].each do |b|
    field b.to_sym, type: Boolean
    index({ b.to_s => 1 })
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

  def self.mutual(a, b)
    Follow.find_by(follower: a, followee: b) && Follow.find_by(follower: b, followee: a)
  end

  has_many :notifications, as: :notifiable, dependent: :destroy
end
