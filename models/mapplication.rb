class Mapplication
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :gathering, index: true
  belongs_to :account, class_name: 'Account', inverse_of: :mapplications, index: true
  belongs_to :processed_by, class_name: 'Account', inverse_of: :mapplications_processed, index: true, optional: true

  field :status, type: String
  field :answers, type: Array

  def self.admin_fields
    {
      summary: { type: :text, index: false, edit: false },
      account_id: :lookup,
      gathering_id: :lookup,
      verdicts: :collection,
      status: :select,
      answers: { type: :text_area, disabled: true }
    }
  end

  has_many :verdicts, dependent: :destroy
  # has_one :membership, :dependent => :destroy

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  def discussers
    gathering.discussers.and(:id.in => (verdicts.pluck(:account_id) + gathering.admins.pluck(:id)))
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
    account.notifications_as_notifiable.create! circle: gathering, type: 'mapplication_removed' unless prevent_notifications
  end

  def self.pending
    self.and(status: 'pending')
  end

  def self.paused
    self.and(status: 'paused')
  end

  def acceptable?
    status == 'pending' && (!gathering.member_limit or (gathering.memberships.count < gathering.member_limit)) && (gathering.threshold == 0 || verdicts.proposers.count > 0)
  end

  def meets_threshold
    gathering.threshold && (verdicts.proposers.count + (gathering.enable_supporters ? verdicts.supporters.count : 0)) >= gathering.threshold
  end

  def accept
    mapplication = self
    account = mapplication.account
    gathering = mapplication.gathering
    update_attribute(:status, 'accepted')
    gathering.memberships.create! account: account, mapplication: mapplication
  end

  def name
    "#{account.name}'s application"
  end

  def summary
    "#{account.name} - #{gathering.name}"
  end

  def self.statuses
    %w[pending accepted paused]
  end

  def label
    case status
    when 'pending' then 'primary'
    when 'accepted' then 'success'
    when 'paused' then 'warning'
    end
  end
end
