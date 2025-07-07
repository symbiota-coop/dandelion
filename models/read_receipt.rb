class ReadReceipt
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :comment, index: true
  belongs_to_without_parent_validation :account, index: true

  def self.admin_fields
    {
      comment_id: :lookup,
      account_id: :lookup
    }
  end

  validates_uniqueness_of :account, scope: :comment
end
