module GatheringAssociations
  extend ActiveSupport::Concern

  included do
    belongs_to :account, index: true

    has_many :notifications_as_notifiable, as: :notifiable, dependent: :destroy, class_name: 'Notification', inverse_of: :notifiable
    has_many :notifications_as_circle, as: :circle, dependent: :destroy, class_name: 'Notification', inverse_of: :circle

    has_many :memberships, dependent: :destroy
    has_many :mapplications, dependent: :destroy
    has_many :verdicts, dependent: :destroy
    has_many :payments, dependent: :nullify
    has_many :payment_attempts, dependent: :nullify
    has_many :events, dependent: :nullify

    # Timetable
    has_many :timetables, dependent: :destroy
    has_many :spaces, dependent: :destroy
    has_many :tslots, dependent: :destroy
    has_many :tactivities, dependent: :destroy
    has_many :attendances, dependent: :destroy
    # Teams
    has_many :teams, dependent: :destroy
    has_many :teamships, dependent: :destroy
    # Rotas
    has_many :rotas, dependent: :destroy
    has_many :roles, dependent: :destroy
    has_many :rslots, dependent: :destroy
    has_many :shifts, dependent: :destroy
    # Options
    has_many :options, dependent: :destroy
    has_many :optionships, dependent: :destroy
    # Budget
    has_many :spends, dependent: :destroy
    # Inventory
    has_many :inventory_items, dependent: :destroy
    #  Photos
    has_many :photos, as: :photoable, dependent: :destroy
  end

  def admins
    Account.and(:id.in => memberships.and(admin: true).pluck(:account_id))
  end

  def members
    Account.and(:id.in => memberships.pluck(:account_id))
  end

  def admin_emails
    Account.and(:id.in => memberships.and(admin: true).pluck(:account_id)).pluck(:email)
  end

  def discussers
    Account.and(:id.in => memberships.and(:unsubscribed.ne => true).pluck(:account_id))
  end
end
