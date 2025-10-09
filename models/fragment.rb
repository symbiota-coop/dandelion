class Fragment
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  belongs_to_without_parent_validation :event, index: true, optional: true

  field :key, type: String
  # index({ key: 1 }, { unique: true })
  field :value, type: String
  field :expires, type: Time

  validates_presence_of :key, :value, :expires
  validates_uniqueness_of :key

  def self.admin_fields
    {
      key: { type: :text, full: true },
      value: :text_area,
      expires: :datetime,
      event_id: :lookup
    }
  end
end
