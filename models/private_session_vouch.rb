# Someone vouching for a private session: they know it's good, and may say why in a testimonial. One each, and not
# for your own session
class PrivateSessionVouch
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  TESTIMONIAL_MAX_LENGTH = 1000

  belongs_to_without_parent_validation :private_session
  belongs_to_without_parent_validation :account

  field :testimonial, type: String

  validates_uniqueness_of :account, scope: :private_session
  validates_length_of :testimonial, maximum: TESTIMONIAL_MAX_LENGTH, allow_nil: true

  before_validation do
    self.testimonial = testimonial&.strip
    self.testimonial = nil if testimonial.blank?
    errors.add(:account, "can't vouch for their own session") if private_session && account_id == private_session.account_id
  end

  after_create { private_session&.refresh_vouches_count }
  after_destroy { private_session&.refresh_vouches_count }
end
