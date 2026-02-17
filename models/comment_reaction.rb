class CommentReaction
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, inverse_of: :comment_reactions_as_creator
  belongs_to_without_parent_validation :comment
  belongs_to_without_parent_validation :post
  belongs_to_without_parent_validation :commentable, polymorphic: true

  field :body, type: String


  before_validation do
    self.post = comment.post if comment
    self.commentable = post.commentable if post
    self.body = body.split.first if body
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
