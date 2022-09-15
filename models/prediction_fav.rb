class PredictionFav
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true
  belongs_to :prediction, index: true

  field :index, type: Integer

  def self.admin_fields
    {
      index: :number,
      prediction_id: :lookup,
      account_id: :lookup
    }
  end

  def name
    'Imagine'
  end

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  validates_presence_of :index
  validates_uniqueness_of :index, scope: :prediction

  before_validation do
    self.account = prediction.account unless account
  end

  def discussers
    Account.and(:id.in => [account.id])
  end
end
