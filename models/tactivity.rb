class Tactivity < DandelionModel
  extend Dragonfly::Model
  include ImageWithValidation

  belongs_to_without_parent_validation :timetable, index: true
  belongs_to_without_parent_validation :account, class_name: 'Account', inverse_of: :tactivities, index: true
  belongs_to_without_parent_validation :gathering, index: true
  belongs_to_without_parent_validation :membership, index: true

  belongs_to_without_parent_validation :space, index: true, optional: true
  belongs_to_without_parent_validation :tslot, index: true, optional: true
  belongs_to_without_parent_validation :scheduled_by, class_name: 'Account', inverse_of: :tactivities_scheduled, index: true, optional: true

  field :name, type: String
  field :description, type: String
  field :image_uid, type: String

  def tslot_ids
    [''] + timetable.tslots.map { |tslot| [tslot.name, tslot.id] }
  end

  def space_ids
    [''] + timetable.spaces.map { |space| [space.name, space.id] }
  end

  def self.admin_fields
    {
      name: :text,
      description: :text_area,
      image: :image,
      account_id: :lookup,
      space_id: :lookup,
      tslot_id: :lookup,
      timetable_id: :lookup,
      gathering_id: :lookup,
      membership_id: :lookup
    }
  end

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  before_validation do
    self.timetable = space.timetable if space
    self.gathering = timetable.gathering if timetable
    self.membership = gathering.memberships.find_by(account: account) if gathering && account && !membership

    self.space = nil if tslot.nil?
    self.tslot = nil if space.nil?
  end

  validates_presence_of :name
  validates_uniqueness_of :space, scope: :tslot, allow_nil: true

  has_many :attendances, dependent: :destroy
  def attendees
    Account.and(:id.in => attendances.pluck(:account_id))
  end

  def discussers
    gathering.discussers.and(:id.in => attendances.pluck(:account_id) + [account.id])
  end

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'created_tactivity'
  end

  def circle
    timetable.gathering
  end

  def self.human_attribute_name(attr, options = {})
    {
      name: 'Activity name',
      tslot_id: 'Slot'
    }[attr.to_sym] || super
  end
end
