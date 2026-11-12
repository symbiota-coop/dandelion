class Membership
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include MembershipRows

  belongs_to_without_parent_validation :gathering
  belongs_to_without_parent_validation :account, class_name: 'Account', inverse_of: :memberships
  belongs_to_without_parent_validation :added_by, class_name: 'Account', inverse_of: :memberships_added, optional: true
  belongs_to_without_parent_validation :admin_status_changed_by, class_name: 'Account', inverse_of: :memberships_admin_status_changed, optional: true
  belongs_to_without_parent_validation :mapplication, optional: true

  field :paid, type: Integer
  field :desired_threshold, type: Integer
  field :requested_contribution, type: Integer
  field :invitations_granted, type: Integer
  field :shift_points_required, type: Float
  field :answers, type: Array

  %w[admin unsubscribed hide_from_sidebar added_without_applying].each do |b|
    field b.to_sym, type: Boolean
  end

  validates_uniqueness_of :account, scope: :gathering
  # Whole numbers of the gathering's currency, and of people; a blank invitations_granted falls back to the gathering's
  validates :paid, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :invitations_granted, numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }
  # Shifts can be worth fractions of a point; blank means not set yet
  validates :shift_points_required, numericality: { greater_than_or_equal_to: 0, less_than: Float::INFINITY, allow_nil: true }

  before_validation do
    errors.add(:gathering, 'is full') if new_record? && gathering.member_limit && (gathering.memberships(true).count >= gathering.member_limit)
    self.desired_threshold = 0 if desired_threshold && (desired_threshold < 0)
    # Only when nothing was given: a value that isn't a number (also nil once cast) is left for the validation to refuse
    self.paid = 0 if paid_before_type_cast.nil?
    self.requested_contribution = 0 if requested_contribution.nil?
  end

  before_create do
    # Stored rather than derived from added_by_id, which is nullified if the adder deletes their account
    # Applications submitted while signed out for an existing account don't count as the account holder applying
    self.added_without_applying = (added_by_id || mapplication&.submitted_signed_out) && !gathering.mapplications.and(account_id: account_id, :submitted_signed_out.ne => true).exists? ? true : false
  end

  attr_accessor :prevent_notifications

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'joined_gathering' unless prevent_notifications
    gathering.set(membership_count: gathering.memberships.count)
    # Only follow on a member's behalf if they chose to join, since following grants access to 'People I follow' details
    gathering.memberships.each do |membership|
      next if membership.account_id == account_id

      Follow.create follower: membership.account, followee: account, unsubscribed: true unless membership.added_without_applying
      Follow.create follower: account, followee: membership.account, unsubscribed: true unless added_without_applying
    end
    if (general = gathering.teams.find_by(name: 'General'))
      general.teamships.create! account: account, gathering: gathering, prevent_notifications: true
    end
    account.account_notification_cache&.refresh_gathering_ids!
  end

  def circle
    gathering
  end

  # A gathering keeps at least one admin of its own, so its only admin can't leave, be removed or be unadmined
  def only_admin?
    admin? && !gathering.memberships.and(admin: true, :id.ne => id).exists?
  end

  after_create :send_email
  def send_email
    account = self.account
    gathering = self.gathering

    sign_in_details = if account.has_signed_in?
                        %(<a href="#{ENV['BASE_URI']}/g/#{gathering.slug}?link_token=%recipient.token%">Sign in to get involved with the co-creation!</a>)
                      else
                        %(<a href="#{ENV['BASE_URI']}/accounts/edit?link_token=%recipient.token%&slug=#{gathering.slug}">Click here to finish setting up your account and get involved with the co-creation!</a>)
                      end

    Mailer.deliver(to: account, subject: "You're now a member of #{gathering.name}", html: gathering.welcome_email_html(sign_in_details))
  end
  handle_asynchronously :send_email

  after_destroy do
    # Only create notification if account is not being destroyed (voluntary leave vs. account deletion)
    account.notifications_as_notifiable.create! circle: gathering, type: 'left_gathering' if account && !account.flagged_for_destroy? && gathering && !gathering.flagged_for_destroy?
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
    account.account_notification_cache&.refresh_gathering_ids!
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
      c += optionship.option&.cost_per_person.to_i unless optionship.flagged_for_destroy?
    end
    c
  end

  def update_requested_contribution
    set(requested_contribution: calculate_requested_contribution)
  end

  # Merging accounts (Account#merge): the victim's membership of the same gathering goes with the victim, so this one
  # takes its rows (shifts, attendances, payments...), which would go with it, and what it was granted and paid
  def absorb_duplicate!(victim)
    set(admin: true) if victim.admin
    inc(paid: victim.paid) if victim.paid.to_i.positive?
    set(mapplication_id: victim.mapplication_id) if victim.mapplication_id && !mapplication_id
    # Its after_destroy destroys its mapplication, which may now be this one's
    victim.set(mapplication_id: nil)
    absorb_has_many!(victim)
    update_requested_contribution
  end

  def owes_contribution?
    requested_contribution.to_i.positive? && paid.to_i < requested_contribution
  end

  def confirmed?
    !gathering.demand_payment or paid > 0 or admin?
  end

  def self.protected_attributes
    %w[admin]
  end
end
