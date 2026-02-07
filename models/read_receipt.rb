class ReadReceipt
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :comment
  belongs_to_without_parent_validation :account

  def self.admin_fields
    {
      comment_id: :lookup,
      account_id: :lookup
    }
  end

  validates_uniqueness_of :account, scope: :comment
end
