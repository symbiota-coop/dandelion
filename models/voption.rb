class Voption
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :comment
  belongs_to_without_parent_validation :account

  field :text, type: String

  has_many :votes, dependent: :destroy

  validates_presence_of :text

  # Its creator, the author of the comment whose poll it's in, or a site admin
  def removable_by?(account)
    return false unless account

    account.admin? || account_id == account.id || comment&.account_id == account.id
  end
end
