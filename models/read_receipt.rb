class ReadReceipt
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :comment, index: true
  belongs_to :account, index: true

  def self.admin_fields
    {
      comment_id: :lookup,
      account_id: :lookup
    }
  end

  validates_uniqueness_of :account, scope: :comment
end
