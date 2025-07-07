class EventStar
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :event, index: true
  belongs_to_without_parent_validation :account, index: true

  validates_uniqueness_of :event, scope: :account

  def self.admin_fields
    {
      event_id: :lookup,
      account_id: :lookup
    }
  end
end
