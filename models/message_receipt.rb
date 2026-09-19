class MessageReceipt
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :messenger, class_name: 'Account', inverse_of: :message_receipts_as_messenger
  belongs_to_without_parent_validation :messengee, class_name: 'Account', inverse_of: :message_receipts_as_massangee

  field :received_at, type: Time

  validates_uniqueness_of :messenger, scope: :messengee

  def self.mark_read!(messenger:, messengee:)
    latest = Message.and(messenger: messenger, messengee: messengee).order('created_at desc').first
    receipt = find_or_create_by(messenger: messenger, messengee: messengee)
    return receipt if receipt.received_at && (!latest || receipt.received_at > latest.created_at)

    receipt.set(received_at: Time.now)
    receipt
  end
end
