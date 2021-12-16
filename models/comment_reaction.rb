class CommentReaction
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true, inverse_of: :comment_reactions_as_creator
  belongs_to :comment, index: true
  belongs_to :post, index: true
  belongs_to :commentable, polymorphic: true, index: true

  field :body, type: String

  def self.admin_fields
    {
      body: :text,
      comment_id: :lookup,
      account_id: :lookup,
      commentable_id: :text,
      commentable_type: :select,
      post_id: :lookup
    }
  end

  before_validation do
    self.post = comment.post if comment
    self.commentable = post.commentable if post
    self.body = body.split(' ').first if body
  end

  validates_uniqueness_of :account, scope: :comment

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'reacted_to_a_comment' if account && circle
  end

  def circle
    comment.circle
  end

  def self.commentable_types
    Post.commentable_types
  end
end
