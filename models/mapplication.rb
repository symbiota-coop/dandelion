class Mapplication
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :account, class_name: 'Account', inverse_of: :mapplications
  belongs_to_without_parent_validation :processed_by, class_name: 'Account', inverse_of: :mapplications_processed, optional: true

  field :status, type: String
  field :answers, type: Array
  field :submitted_signed_out, type: Boolean


  has_many :verdicts, dependent: :destroy
  # has_one :membership, :dependent => :destroy

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  def discussers
    gathering.discussers.and(:id.in => (verdicts.pluck(:account_id) + gathering.admin_ids))
  end

  validates_presence_of :status
  validates_uniqueness_of :account, scope: :gathering

  attr_accessor :prevent_notifications

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'applied'
  end

  def circle
    gathering
  end

  after_destroy do
    account.notifications_as_notifiable.create! circle: gathering, type: 'mapplication_removed' if gathering && !gathering.flagged_for_destroy? && !prevent_notifications
  end

  def self.pending
    self.and(status: 'pending')
  end

  def self.paused
    self.and(status: 'paused')
  end

  def acceptable?
    status == 'pending' && (!gathering.member_limit or (gathering.memberships.count < gathering.member_limit)) && (gathering.threshold == 0 || verdicts.proposers.exists?)
  end

  def meets_threshold
    gathering.threshold && (verdicts.proposers.count + (gathering.enable_supporters ? verdicts.supporters.count : 0)) >= gathering.threshold
  end

  # Whether it was: not if the gathering filled up, or another acceptance made the membership, since acceptable? was
  # checked
  def accept
    membership = gathering.memberships.create(account: account, unsubscribed: true, mapplication: self)
    set(status: 'accepted') if membership.persisted?
    membership.persisted?
  end

  def name
    "#{account.name}'s application"
  end

  def summary
    "#{account.name} - #{gathering.name}"
  end

  # Merging accounts (Account#merge): the victim's application to the same gathering goes with the victim, so this one
  # takes its acceptance, the memberships that point at it, and its verdicts and discussion
  def absorb_duplicate!(victim)
    set(status: 'accepted') if victim.status == 'accepted'
    Membership.and(mapplication_id: victim.id).update_all(mapplication_id: id)
    absorb_has_many!(victim)
  end

  def self.statuses
    %w[pending accepted paused]
  end

  def label
    case status
    when 'pending', 'accepted' then 'primary'
    when 'paused' then 'warning'
    end
  end
end
