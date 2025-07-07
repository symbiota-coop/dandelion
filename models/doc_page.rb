class DocPage < DandelionModel
  field :name, type: String
  field :slug, type: String
  field :body, type: String
  field :priority, type: Integer

  validates_presence_of :name, :slug
  validates_uniqueness_of :slug

  def self.admin_fields
    {
      name: :text,
      slug: :slug,
      body: :text_area,
      priority: :number
    }
  end

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  def discussers
    Account.and(admin: true)
  end
end
