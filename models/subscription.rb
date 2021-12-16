class Subscription
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true, inverse_of: :subscriptions_as_creator
  belongs_to :post, index: true
  belongs_to :commentable, polymorphic: true, index: true

  def self.admin_fields
    {
      id: { type: :text, edit: false },
      post_id: :lookup,
      account_id: :lookup,
      commentable_id: :text,
      commentable_type: :select
    }
  end

  validates_presence_of :post, :account, :commentable
  validates_uniqueness_of :account, scope: :post

  before_validation do
    self.commentable = post.commentable if post
  end

  def self.commentable_types
    Post.commentable_types
  end
end
