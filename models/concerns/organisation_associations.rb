module OrganisationAssociations
  extend ActiveSupport::Concern

  included do
    belongs_to_without_parent_validation :account, inverse_of: :organisations, optional: true
    belongs_to_without_parent_validation :referrer, class_name: 'Account', inverse_of: :organisations_as_referrer, optional: true
    belongs_to_without_parent_validation :reward_claimer, class_name: 'Account', inverse_of: :organisations_as_reward_claimer, optional: true

    has_many :stripe_charges, dependent: :destroy
    has_many :stripe_transactions, dependent: :destroy

    has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

    has_many :organisation_edges_as_source, class_name: 'OrganisationEdge', inverse_of: :source, dependent: :destroy
    has_many :organisation_edges_as_sink, class_name: 'OrganisationEdge', inverse_of: :sink, dependent: :destroy

    has_many :notifications_as_notifiable, as: :notifiable, dependent: :destroy, class_name: 'Notification', inverse_of: :notifiable
    has_many :notifications_as_circle, as: :circle, dependent: :destroy, class_name: 'Notification', inverse_of: :circle

    has_many :events, dependent: :nullify

    has_many :carousels, dependent: :destroy

    has_many :organisation_contributions, dependent: :destroy

    has_many :cohostships, dependent: :destroy
    has_many :activities, dependent: :destroy
    has_many :organisationships, dependent: :destroy
    has_many :pmails, dependent: :destroy

    has_many :attachments, dependent: :destroy
    has_many :local_groups, dependent: :destroy
    has_many :organisation_tiers, dependent: :destroy

    has_many :orders_as_affiliate, class_name: 'Order', as: :affiliate, dependent: :nullify

    with_options class_name: 'Account', through: :organisationships do
      has_many_through :admins, conditions: { admin: true }
      has_many_through :admins_receiving_feedback, conditions: { admin: true, receive_feedback: true }
      has_many_through :revenue_sharers, conditions: { :stripe_connect_json.ne => nil }
      has_many_through :monthly_donors, conditions: { :monthly_donation_method.ne => nil }
      has_many_through :subscribed_monthly_donors, conditions: { :monthly_donation_method.ne => nil, unsubscribed: false }
      has_many_through :not_monthly_donors, conditions: { monthly_donation_method: nil }
      has_many_through :subscribed_not_monthly_donors, conditions: { monthly_donation_method: nil, unsubscribed: false }
    end
  end

  def subscribed_member_ids
    Account.and(subscribed_organisation_ids_cache: id).pluck(:id)
  end

  def subscribed_members
    Account.and(subscribed_organisation_ids_cache: id)
  end

  def unsubscribed_member_ids
    Account.and(unsubscribed_organisation_ids_cache: id).pluck(:id)
  end

  def unsubscribed_members
    Account.and(unsubscribed_organisation_ids_cache: id)
  end

  def news
    pmails.and(mailable: nil, monthly_donors: false, facilitators: false).and(:sent_at.ne => nil).order('sent_at desc')
  end

  def cohosts
    Organisation.and(:id.in => events.pluck(:cohosts_ids_cache).flatten)
  end

  def cohosted_events
    Event.and(cohosts_ids_cache: id)
  end

  def events_including_cohosted
    # was Event.and(:id.in => events.pluck(:id) + cohostships.pluck(:event_id))
    Event.unscoped.or({ organisation_id: id }, { cohosts_ids_cache: id }).and(deleted_at: nil)
  end

  def featured_events
    primary_host_featured_events = events.live.public.future_and_current_featured.and(has_image: true).and(featured: true)

    featured_cohostship_event_ids = cohostships.and(featured: true).pluck(:event_id)
    cohost_featured_events = Event.live.public.future_and_current_featured.and(has_image: true).and(:id.in => featured_cohostship_event_ids)

    Event.and(:id.in => primary_host_featured_events.pluck(:id) + cohost_featured_events.pluck(:id)).order('start_time asc').limit(20).reject(&:sold_out?)
  end

  def contributable_events
    events.live
  end

  def orders
    Order.and(:event_id.in => events.pluck(:id))
  end

  def event_feedbacks
    EventFeedback.and(:event_id.in => events_including_cohosted.pluck(:id))
  end

  def unscoped_event_feedbacks
    EventFeedback.unscoped.and(:event_id.in => events_including_cohosted.pluck(:id))
  end

  def event_tags
    EventTag.and(:id.in => EventTagship.and(:event_id.in => events.pluck(:id)).pluck(:event_tag_id))
  end

  def activity_tags
    ActivityTag.and(:id.in => ActivityTagship.and(:activity_id.in => activities.pluck(:id)).pluck(:activity_tag_id))
  end

  def members
    Account.and(organisation_ids_cache: id)
  end

  def subscribed_accounts
    subscribed_members.and(unsubscribed: false)
  end

  def facilitators
    Account.and(:id.in =>
        EventFacilitation.and(:event_id.in => events.future.pluck(:id)).pluck(:account_id) +
        Activityship.and(:activity_id.in => activity_ids, :admin => true).pluck(:account_id))
  end
end
