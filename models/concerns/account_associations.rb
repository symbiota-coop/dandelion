module AccountAssociations
  extend ActiveSupport::Concern

  included do
    has_one :account_recommendation_cache, dependent: :destroy
    has_one :account_notification_cache, dependent: :destroy

    has_many :drafts, dependent: :destroy

    has_many :rpayments, dependent: :nullify

    has_many :stripe_charges

    has_many :account_contributions, dependent: :destroy

    has_many :sign_ins, dependent: :destroy

    has_many :pmails, dependent: :nullify

    has_many :uploads, dependent: :destroy

    has_many :organisations, dependent: :nullify
    has_many :organisations_as_referrer, class_name: 'Organisation', inverse_of: :referrer, dependent: :nullify
    has_many :organisationships, class_name: 'Organisationship', inverse_of: :account, dependent: :destroy
    has_many :organisationships_as_referrer, class_name: 'Organisationship', inverse_of: :referrer, dependent: :nullify

    has_many :creditings, dependent: :nullify

    has_many :activity_applications, class_name: 'ActivityApplication', inverse_of: :account, dependent: :destroy
    has_many :statused_activity_applications, class_name: 'ActivityApplication', inverse_of: :statused_by, dependent: :nullify

    has_many :events, class_name: 'Event', inverse_of: :account, dependent: :nullify
    has_many :events_coordinating, class_name: 'Event', inverse_of: :coordinator, dependent: :nullify
    has_many :events_revenue_sharing, class_name: 'Event', inverse_of: :revenue_sharer, dependent: :nullify
    has_many :events_organising, class_name: 'Event', inverse_of: :organiser, dependent: :nullify
    has_many :events_last_saver, class_name: 'Event', inverse_of: :last_saved_by, dependent: :nullify
    has_many :event_stars, dependent: :destroy
    has_many :zoomships, dependent: :destroy
    has_many :event_facilitations, dependent: :destroy
    has_many :waitships, dependent: :destroy
    has_many :event_feedbacks, dependent: :nullify

    has_many :activities, dependent: :nullify
    has_many :activityships, dependent: :destroy

    has_many :local_groups, dependent: :nullify
    has_many :local_groupships, dependent: :destroy

    has_many :gatherings, dependent: :nullify

    has_many :mapplications, class_name: 'Mapplication', inverse_of: :account, dependent: :destroy
    has_many :mapplications_processed, class_name: 'Mapplication', inverse_of: :processed_by, dependent: :nullify

    has_many :verdicts, dependent: :destroy

    has_many :memberships, class_name: 'Membership', inverse_of: :account, dependent: :destroy
    has_many :memberships_added, class_name: 'Membership', inverse_of: :added_by, dependent: :nullify
    has_many :memberships_admin_status_changed, class_name: 'Membership', inverse_of: :admin_status_changed_by, dependent: :nullify

    has_many :payments, dependent: :destroy
    has_many :payment_attempts, dependent: :destroy

    # Timetable
    has_many :timetables, dependent: :nullify
    has_many :tactivities, class_name: 'Tactivity', inverse_of: :account, dependent: :destroy
    has_many :tactivities_scheduled, class_name: 'Tactivity', inverse_of: :scheduled_by, dependent: :nullify
    has_many :attendances, dependent: :destroy
    # Teams
    has_many :teams, dependent: :nullify
    has_many :teamships, dependent: :destroy
    has_many :read_receipts, dependent: :destroy
    has_many :options, dependent: :destroy
    has_many :votes, dependent: :destroy
    # Rotas
    has_many :rotas, dependent: :nullify
    has_many :shifts, dependent: :destroy
    # Options
    has_many :options, dependent: :nullify
    has_many :optionships, dependent: :destroy
    # Budget
    has_many :spends, dependent: :destroy
    # Inventory
    has_many :inventory_items_listed, class_name: 'InventoryItem', inverse_of: :account, dependent: :nullify
    has_many :inventory_items_provided, class_name: 'InventoryItem', inverse_of: :responsible, dependent: :nullify
    # Follows
    has_many :follows_as_follower, class_name: 'Follow', inverse_of: :follower, dependent: :destroy
    has_many :follows_as_followee, class_name: 'Follow', inverse_of: :followee, dependent: :destroy

    # Messages
    has_many :messages_as_messenger, class_name: 'Message', inverse_of: :messenger, dependent: :destroy
    has_many :messages_as_messengee, class_name: 'Message', inverse_of: :messengee, dependent: :destroy

    # MessageReceipts
    has_many :message_receipts_as_messenger, class_name: 'MessageReceipt', inverse_of: :messenger, dependent: :destroy
    has_many :message_receipts_as_messengee, class_name: 'MessageReceipt', inverse_of: :messengee, dependent: :destroy

    has_many :photos, dependent: :destroy

    has_many :notifications_as_notifiable, as: :notifiable, dependent: :destroy, class_name: 'Notification', inverse_of: :notifiable
    has_many :notifications_as_circle, as: :circle, dependent: :destroy, class_name: 'Notification', inverse_of: :circle

    has_many :posts_as_creator, class_name: 'Post', inverse_of: :account, dependent: :destroy
    has_many :subscriptions_as_creator, class_name: 'Subscription', inverse_of: :account, dependent: :destroy
    has_many :comments_as_creator, class_name: 'Comment', inverse_of: :account, dependent: :destroy
    has_many :comment_reactions_as_creator, class_name: 'CommentReaction', inverse_of: :account, dependent: :destroy

    has_many :orders, class_name: 'Order', inverse_of: :account, dependent: :nullify
    has_many :orders_as_revenue_sharer, class_name: 'Order', inverse_of: :revenue_sharer, dependent: :nullify
    has_many :orders_as_affiliate, class_name: 'Order', as: :affiliate, dependent: :nullify

    has_many :tickets, dependent: :nullify
    has_many :donations, dependent: :nullify

    has_many :discount_codes, dependent: :nullify

    has_many :provider_links, dependent: :destroy
    accepts_nested_attributes_for :provider_links, reject_if: lambda { |attributes|
      return true if attributes[:id].present? && attributes[:_destroy].blank? && !ProviderLink.exists?(attributes[:id])

      false
    }

    has_many_through :activities_following, class_name: 'Activity', through: :activityships
    has_many_through :local_groups_following, class_name: 'LocalGroup', through: :local_groupships
    has_many_through :followers, class_name: 'Account', through: :follows_as_followee, foreign_key: :follower_id

    with_options class_name: 'Account', through: :follows_as_follower, foreign_key: :followee_id do
      has_many_through :following_starred, conditions: { starred: true }
      has_many_through :following
      has_many_through :network
    end

    with_options class_name: 'Organisation', through: :organisationships do
      has_many_through :organisations_following
      has_many_through :organisations_monthly_donor, conditions: { :monthly_donation_method.ne => nil }
    end
  end

  def event_feedbacks_as_facilitator
    EventFeedback.and(:event_id.in => event_facilitations.pluck(:event_id))
  end

  def unscoped_event_feedbacks_as_facilitator
    EventFeedback.unscoped.and(:event_id.in => event_facilitations.pluck(:event_id))
  end

  def network_notifications
    # Use cached IDs if available and valid, otherwise refresh cache
    cache = account_notification_cache || create_account_notification_cache
    unless cache.cache_valid?
      cache.refresh!
      cache.reload
    end

    Notification.or(
      { :circle_type => 'Gathering', :circle_id.in => cache.gathering_ids },
      { :circle_type => 'Account', :circle_id.in => cache.account_ids },
      { :circle_type => 'Activity', :circle_id.in => cache.activity_ids },
      { :circle_type => 'LocalGroup', :circle_id.in => cache.local_group_ids },
      {
        :circle_type => 'Organisation',
        :circle_id.in => cache.organisations_following_ids,
        :type.ne => 'commented'
      },
      {
        :circle_type => 'Organisation',
        :circle_id.in => cache.organisations_monthly_donor_ids,
        :type => 'commented'
      }
    )
  end

  def messages
    Message.or({ messenger: self }, { messengee: self })
  end

  def my_events
    Event.and(has_organisation: true).and(:id.in =>
        tickets.complete.pluck(:event_id) +
        event_facilitations.pluck(:event_id) +
        events_coordinating_ids +
        events_revenue_sharing_ids +
        events_organising_ids +
        event_stars.pluck(:event_id))
  end

  def upcoming_events
    my_events.future_and_current
  end

  def previous_events
    my_events.past
  end
end
