module OrganisationAssociations
  extend ActiveSupport::Concern

  included do
    belongs_to_without_parent_validation :account, inverse_of: :organisations, index: true, optional: true
    belongs_to_without_parent_validation :referrer, class_name: 'Account', inverse_of: :organisations_as_referrer, index: true, optional: true

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
  end

  def news
    pmails.and(mailable: nil, monthly_donors: nil, facilitators: nil).and(:sent_at.ne => nil).order('sent_at desc')
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
    primary_host_featured_events = events.live.future_and_current.and(:image_uid.ne => nil).and(featured: true)

    featured_cohostship_event_ids = cohostships.and(featured: true).pluck(:event_id)
    cohost_featured_events = Event.live.future_and_current.and(:image_uid.ne => nil).and(:id.in => featured_cohostship_event_ids)

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
    subscribed_members.and(:unsubscribed.in => [nil, false])
  end

  def subscribed_members
    Account.and(:id.in => organisationships.and(:unsubscribed.in => [nil, false]).pluck(:account_id))
  end

  def unsubscribed_members
    Account.and(:id.in => organisationships.and(unsubscribed: true).pluck(:account_id))
  end

  def admins
    Account.and(:id.in => organisationships.and(admin: true).pluck(:account_id))
  end

  def admins_receiving_feedback
    Account.and(:id.in => organisationships.and(admin: true).and(receive_feedback: true).pluck(:account_id))
  end

  def revenue_sharers
    Account.and(:id.in => organisationships.and(:stripe_connect_json.ne => nil).pluck(:account_id))
  end

  def monthly_donors
    Account.and(:id.in => organisationships.and(:monthly_donation_method.ne => nil).pluck(:account_id))
  end

  def subscribed_monthly_donors
    Account.and(:id.in => organisationships.and(:monthly_donation_method.ne => nil, :unsubscribed.in => [nil, false]).pluck(:account_id))
  end

  def not_monthly_donors
    Account.and(:id.in => organisationships.and(monthly_donation_method: nil).pluck(:account_id))
  end

  def subscribed_not_monthly_donors
    Account.and(:id.in => organisationships.and(:monthly_donation_method => nil, :unsubscribed.in => [nil, false]).pluck(:account_id))
  end

  def facilitators
    Account.and(:id.in =>
        EventFacilitation.and(:event_id.in => events.future.pluck(:id)).pluck(:account_id) +
        Activityship.and(:activity_id.in => activities.pluck(:id), :admin => true).pluck(:account_id))
  end
end
