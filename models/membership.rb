class Membership
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :gathering, index: true
  belongs_to_without_parent_validation :account, class_name: 'Account', inverse_of: :memberships, index: true
  belongs_to_without_parent_validation :added_by, class_name: 'Account', inverse_of: :memberships_added, index: true, optional: true
  belongs_to_without_parent_validation :admin_status_changed_by, class_name: 'Account', inverse_of: :memberships_admin_status_changed, index: true, optional: true
  belongs_to_without_parent_validation :mapplication, index: true, optional: true

  field :paid, type: Integer
  field :desired_threshold, type: Integer
  field :requested_contribution, type: Integer
  field :invitations_granted, type: Integer
  field :shift_points_required, type: Float
  field :answers, type: Array

  %w[admin unsubscribed hide_from_sidebar].each do |b|
    field b.to_sym, type: Boolean
  end

  def self.admin_fields
    {
      account_id: :lookup,
      gathering_id: :lookup,
      mapplication_id: :lookup,
      admin: :check_box,
      paid: :number,
      desired_threshold: :number,
      requested_contribution: :number,
      invitations_granted: :number,
      unsubscribed: :check_box,
      hide_from_sidebar: :check_box,
      answers: { type: :text_area, disabled: true }
    }
  end

  validates_uniqueness_of :account, scope: :gathering

  before_validation do
    errors.add(:gathering, 'is full') if new_record? && gathering.member_limit && (gathering.memberships(true).count >= gathering.member_limit)
    self.desired_threshold = 0 if desired_threshold && (desired_threshold < 0)
    self.paid = 0 if paid.nil?
    self.requested_contribution = 0 if requested_contribution.nil?
  end

  attr_accessor :prevent_notifications

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'joined_gathering' unless prevent_notifications
    gathering.set(membership_count: gathering.memberships.count)
    gathering.members.each do |member|
      next if member.id == account.id

      Follow.create follower: member, followee: account, unsubscribed: true
      Follow.create follower: account, followee: member, unsubscribed: true
    end
    if (general = gathering.teams.find_by(name: 'General'))
      general.teamships.create! account: account, prevent_notifications: true
    end
    # Refresh gathering IDs in notification cache for this account
    account.account_notification_cache&.refresh_gathering_ids!
  end

  def circle
    gathering
  end

  def proposed_by
    mapplication ? mapplication.verdicts.proposers.map(&:account) : ([added_by] if added_by)
  end

  after_create :send_email
  def send_email
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self.account
    gathering = self.gathering

    sign_in_details = if account.has_signed_in?
                        %(<a href="#{ENV['BASE_URI']}/g/#{gathering.slug}?sign_in_token=%recipient.token%">Sign in to get involved with the co-creation!</a>)
                      else
                        %(<a href="#{ENV['BASE_URI']}/accounts/edit?sign_in_token=%recipient.token%&slug=#{gathering.slug}">Click here to finish setting up your account and get involved with the co-creation!</a>)
                      end

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "You're now a member of #{gathering.name}"
    batch_message.body_html EmailHelper.html(content: gathering.welcome_email) do |content|
      content.gsub('%gathering.name%', gathering.name)
             .gsub('%sign_in_details%', sign_in_details)
    end

    batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })

    batch_message.finalize if Padrino.env == :production
  end
  handle_asynchronously :send_email

  after_destroy do
    account.notifications_as_notifiable.create! circle: gathering, type: 'left_gathering'
    gathering.set(membership_count: gathering.memberships.count)
    if mapplication
      mapplication.prevent_notifications = true
      mapplication.destroy
    end
    %w[teams tactivities mapplications].each do |items|
      gathering.send(items).each do |item|
        item.subscriptions.and(account: account).destroy_all
      end
    end
    # Refresh gathering IDs in notification cache for this account
    account.account_notification_cache&.refresh_gathering_ids!
  end

  def invitations_extended
    gathering.memberships.and(added_by: account).count
  end

  def smart_invitations_granted
    invitations_granted || gathering.invitations_granted
  end

  def invitations_remaining
    smart_invitations_granted - invitations_extended
  end

  has_many :verdicts, dependent: :destroy
  has_many :payments, dependent: :nullify

  # Timetable
  has_many :tactivities, dependent: :destroy
  has_many :attendances, dependent: :destroy
  # Teams
  has_many :teamships, dependent: :destroy
  has_many :posts, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :comments, dependent: :destroy
  has_many :comment_reactions, dependent: :destroy
  # Rotas
  has_many :shifts, dependent: :destroy
  # Options
  has_many :optionships, dependent: :destroy
  # Budget
  has_many :spends, dependent: :destroy
  #  Inventory
  has_many :inventory_items, dependent: :nullify

  def calculate_requested_contribution
    c = 0
    optionships.each do |optionship|
      c += optionship.option.cost_per_person unless optionship.flagged_for_destroy?
    end
    c
  end

  def update_requested_contribution
    set(requested_contribution: calculate_requested_contribution)
  end

  def confirmed?
    !gathering.demand_payment or paid > 0 or admin?
  end

  def self.protected_attributes
    %w[admin]
  end

  def shift_points
    shifts.map(&:worth).sum
  end
end
