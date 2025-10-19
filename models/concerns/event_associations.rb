module EventAssociations
  extend ActiveSupport::Concern

  included do
    belongs_to_without_parent_validation :account, inverse_of: :events, index: true
    belongs_to_without_parent_validation :organisation, index: true
    belongs_to_without_parent_validation :activity, class_name: 'Activity', inverse_of: :events, optional: true, index: true
    belongs_to_without_parent_validation :feedback_activity, class_name: 'Activity', inverse_of: :events_as_feedback_activity, optional: true, index: true
    belongs_to_without_parent_validation :local_group, optional: true, index: true
    belongs_to_without_parent_validation :coordinator, class_name: 'Account', inverse_of: :events_coordinating, index: true, optional: true
    belongs_to_without_parent_validation :revenue_sharer, class_name: 'Account', inverse_of: :events_revenue_sharing, index: true, optional: true
    belongs_to_without_parent_validation :organiser, class_name: 'Account', inverse_of: :events_organising, index: true, optional: true
    belongs_to_without_parent_validation :last_saved_by, class_name: 'Account', inverse_of: :events_last_saver, index: true, optional: true
    belongs_to_without_parent_validation :gathering, optional: true, index: true

    has_many :fragments, dependent: :destroy

    has_many :stripe_charges

    has_many :rpayments, dependent: :destroy

    has_many :posts, as: :commentable, dependent: :destroy
    has_many :subscriptions, as: :commentable, dependent: :destroy
    has_many :comments, as: :commentable, dependent: :destroy
    has_many :comment_reactions, as: :commentable, dependent: :destroy

    has_many :event_sessions, dependent: :destroy

    has_many :account_contributions, dependent: :nullify

    has_many :cohostships, dependent: :destroy

    has_many :pmails_as_mailable, class_name: 'Pmail', as: :mailable, dependent: :destroy
    has_many :pmails_as_exclusion, class_name: 'Pmail', inverse_of: :event, dependent: :nullify

    has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

    has_many :notifications, as: :notifiable, dependent: :destroy

    has_many :ticket_types, dependent: :destroy
    accepts_nested_attributes_for :ticket_types, allow_destroy: true, reject_if: ->(attributes) { %w[name description price quantity].all? { |f| attributes[f].nil? } }

    has_many :ticket_groups, dependent: :destroy
    accepts_nested_attributes_for :ticket_groups, allow_destroy: true, reject_if: ->(attributes) { %w[name capacity].all? { |f| attributes[f].nil? } }

    has_many :tickets, dependent: :destroy
    has_many :donations, dependent: :nullify
    has_many :orders, dependent: :destroy
    has_many :waitships, dependent: :destroy

    has_many :event_feedbacks, dependent: :destroy
    has_many :event_facilitations, dependent: :destroy

    has_many :zoomships, dependent: :destroy

    has_many :event_tagships, dependent: :destroy
    has_many :event_stars, dependent: :destroy

    has_many_through :cohosts, class_name: 'Organisation', through: :cohostships
    has_many_through :event_tags, through: :event_tagships

    with_options class_name: 'Account' do
      has_many_through :starrers, through: :event_stars
      has_many_through :waiters, through: :waitships
      has_many_through :event_facilitators, through: :event_facilitations
      has_many_through :attendees, through: :tickets, conditions: { payment_completed: true }
      has_many_through :public_attendees, through: :tickets, conditions: { payment_completed: true, show_attendance: true }
      has_many_through :private_attendees, through: :tickets, conditions: { payment_completed: true, show_attendance: false }
    end
  end

  def organisationship_for_discount(account)
    organisationship = nil
    if account
      organisation_and_cohosts.each do |organisation|
        next unless (o = organisation.organisationships.find_by(account: account))

        organisationship = o if o.monthly_donor? && o.monthly_donor_discount > 0 && (!organisationship || o.monthly_donor_discount > organisationship.monthly_donor_discount)
      end
    end
    organisationship
  end

  def revenue_sharer_organisationship
    organisation.organisationships.find_by(:account => revenue_sharer, :stripe_connect_json.ne => nil) if organisation && revenue_sharer
  end

  def circle
    organisation
  end

  def all_discount_codes
    DiscountCode.and(:id.in =>
      discount_codes.pluck(:id) +
      (organisation ? organisation.discount_codes.pluck(:id) : []) +
      (activity ? activity.discount_codes.pluck(:id) : []) +
      (local_group ? local_group.discount_codes.pluck(:id) : []))
  end

  def organisation_and_cohosts
    [organisation] + cohosts
  end

  def unscoped_attendees
    Account.and(:id.in => tickets.unscoped.pluck(:account_id))
  end

  def discussers
    Account.and(:id.in =>
        [account.try(:id), revenue_sharer.try(:id), coordinator.try(:id)].compact +
        event_facilitator_ids +
        tickets.complete.and(subscribed_discussion: true).pluck(:account_id))
  end

  def subscribed_members
    Account.and(:id.in =>
        [account.try(:id), revenue_sharer.try(:id), coordinator.try(:id)].compact +
        event_facilitator_ids +
        attendee_ids)
  end

  def accounts_receiving_feedback
    a = [account, revenue_sharer, coordinator].compact
    a += event_facilitators
    a += organisation.admins_receiving_feedback if organisation
    a += activity.admins_receiving_feedback if activity
    a += local_group.admins_receiving_feedback if local_group
    a.uniq
  end

  def contacts
    a = [account, revenue_sharer, coordinator].compact
    a += event_facilitators
    a.uniq
  end
end
