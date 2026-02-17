class MessageReceipt
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :messenger, class_name: 'Account', inverse_of: :message_receipts_as_messenger
  belongs_to_without_parent_validation :messengee, class_name: 'Account', inverse_of: :message_receipts_as_massangee

  field :received_at, type: Time

  validates_uniqueness_of :messenger, scope: :messengee
end
