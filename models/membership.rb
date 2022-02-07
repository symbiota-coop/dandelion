class Membership
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :gathering, index: true
  belongs_to :account, class_name: 'Account', inverse_of: :memberships, index: true
  belongs_to :added_by, class_name: 'Account', inverse_of: :memberships_added, index: true, optional: true
  belongs_to :admin_status_changed_by, class_name: 'Account', inverse_of: :memberships_admin_status_changed, index: true, optional: true
  belongs_to :mapplication, index: true, optional: true

  field :paid, type: Integer
  field :desired_threshold, type: Integer
  field :requested_contribution, type: Integer
  field :invitations_granted, type: Integer

  %w[admin unsubscribed member_of_facebook_group hide_from_sidebar].each do |b|
    field b.to_sym, type: Boolean
    index({ b.to_s => 1 })
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
      member_of_facebook_group: :check_box
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
    gathering.members.each do |follower|
      Follow.create follower: follower, followee: account, unsubscribed: true
    end
    gathering.members.each do |followee|
      Follow.create follower: account, followee: followee, unsubscribed: true
    end
    if (general = gathering.teams.find_by(name: 'General'))
      general.teamships.create! account: account, prevent_notifications: true
    end
  end

  def circle
    gathering
  end

  def proposed_by
    mapplication ? mapplication.verdicts.proposers.map { |verdict| verdict.account } : ([added_by] if added_by)
  end

  after_create :send_email
  def send_email
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    account = self.account
    gathering = self.gathering

    sign_in_details = if account.sign_ins_count == 0
                        %(<a href="#{ENV['BASE_URI']}/accounts/edit?sign_in_token=%recipient.token%&slug=#{gathering.slug}">Click here to finish setting up your account and get involved with the co-creation!</a>)
                      else
                        %(<a href="#{ENV['BASE_URI']}/g/#{gathering.slug}?sign_in_token=%recipient.token%">Sign in to get involved with the co-creation!</a>)
                      end

    content = gathering.welcome_email
    content = content.gsub('%gathering.name%', gathering.name)
    content = content.gsub('%sign_in_details%', sign_in_details)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject "You're now a member of #{gathering.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_email

  after_destroy do
    account.notifications_as_notifiable.create! circle: gathering, type: 'left_gathering'
    if mapplication
      mapplication.prevent_notifications = true
      mapplication.destroy
    end
    gathering.subscriptions.where(account: account).destroy_all
    %w[teams tactivities mapplications].each do |items|
      gathering.send(items).each do |item|
        item.subscriptions.where(account: account).destroy_all
      end
    end
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
  has_many :payment_attempts, dependent: :nullify

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
    update_attribute(:requested_contribution, calculate_requested_contribution)
  end

  def confirmed?
    !gathering.demand_payment or paid > 0 or admin?
  end

  def self.protected_attributes
    %w[admin]
  end
end
