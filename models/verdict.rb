class Verdict
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true
  belongs_to :gathering, index: true
  belongs_to :membership, index: true
  belongs_to :mapplication, index: true

  field :type, type: String
  field :reason, type: String

  def self.admin_fields
    {
      account_id: :lookup,
      mapplication_id: :lookup,
      gathering_id: :lookup,
      membership_id: :lookup,
      type: :select,
      reason: :text
    }
  end

  validates_presence_of :type
  validates_uniqueness_of :account, scope: :mapplication

  before_validation do
    self.gathering = mapplication.gathering if mapplication
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership

    errors.add(:type, 'is restricted by gathering.proposing_delay') if (type == 'proposer') && gathering && gathering.proposing_delay && ((Time.now - mapplication.created_at) < gathering.proposing_delay.hours)

    errors.add(:type, 'requires a reason') if (type == 'proposer') && gathering && gathering.require_reason_proposer && !reason
    errors.add(:type, 'requires a reason') if (type == 'supporter') && gathering && gathering.require_reason_supporter && !reason
  end

  after_create do
    mapplication.accept if mapplication.acceptable? && mapplication.meets_threshold
  end

  def ed
    "#{type[0..-2]}d"
  end

  def self.types
    %w[proposer supporter]
  end

  def self.proposers
    self.and(type: 'proposer')
  end

  def self.supporters
    self.and(type: 'supporter')
  end
end
