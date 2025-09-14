module OrganisationAssociations
  extend ActiveSupport::Concern

  included do
    belongs_to_without_parent_validation :account, index: true, optional: true

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
    retry_mongo_operation do
      Organisation.and(:id.in => Cohostship.and(:event_id.in => events.pluck(:id)).pluck(:organisation_id))
    end
  end

  def cohosted_events
    Event.and(:id.in => cohostships.pluck(:event_id))
  end

  def events_including_cohosted
    Event.and(:id.in => events.pluck(:id) + cohostships.pluck(:event_id))
  end

  def events_for_search(include_locked: false, include_secret: false, include_all_local_group_events: false)
    events_for_search = Event.and(:id.in =>
        events.and(local_group_id: nil).pluck(:id) +
        events.and(:local_group_id.ne => nil, :locked => true).pluck(:id) +
        (include_all_local_group_events ? events.and(:local_group_id.ne => nil).pluck(:id) : events.and(:local_group_id.ne => nil, :include_in_parent => true).pluck(:id)) +
        cohostships.pluck(:event_id))
    events_for_search = events_for_search.live unless include_locked
    events_for_search = events_for_search.public unless include_secret
    events_for_search
  end

  def featured_events
    # Get events where this organisation is the primary host and event.featured = true
    primary_host_featured_events = events_for_search.future_and_current.and(:locked.ne => true).and(:image_uid.ne => nil).and(featured: true).and(organisation_id: id)

    # Get events where this organisation is a featured cohost (cohostship.featured = true)
    featured_cohostship_event_ids = cohostships.and(featured: true).pluck(:event_id)
    cohost_featured_events = events_for_search.future_and_current.and(:locked.ne => true).and(:image_uid.ne => nil).and(:id.in => featured_cohostship_event_ids)

    # Combine both sets of events and limit to 20, then reject sold out events
    Event.and(:id.in => primary_host_featured_events.pluck(:id) + cohost_featured_events.pluck(:id)).limit(20).reject(&:sold_out?)
  end

  def contributable_events
    events.live
  end

  def orders
    Order.and(:event_id.in => events.pluck(:id))
  end

  def event_feedbacks
    EventFeedback.and(:event_id.in => events.pluck(:id))
  end

  def unscoped_event_feedbacks
    EventFeedback.unscoped.and(:event_id.in => events.pluck(:id))
  end

  def event_tags
    retry_mongo_operation do
      EventTag.and(:id.in => EventTagship.and(:event_id.in => events.pluck(:id)).pluck(:event_tag_id))
    end
  end

  private

  def retry_mongo_operation(max_attempts: 3, &block)
    attempts = 0
    begin
      attempts += 1
      yield
    rescue Mongo::Error::SocketError => e
      if e.message.include?('SSL_read: unexpected eof') && attempts < max_attempts
        sleep(0.5 * attempts) # exponential backoff: 0.5s, 1.0s, 1.5s
        retry
      else
        raise
      end
    end
  end

  def activity_tags
    retry_mongo_operation do
      ActivityTag.and(:id.in => ActivityTagship.and(:activity_id.in => activities.pluck(:id)).pluck(:activity_tag_id))
    end
  end

  def members
    Account.and(organisation_ids_cache: id)
  end

  def subscribed_accounts
    subscribed_members.and(:unsubscribed.ne => true)
  end

  def subscribed_members
    Account.and(:id.in => organisationships.and(:unsubscribed.ne => true).pluck(:account_id))
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
    Account.and(:id.in => organisationships.and(:monthly_donation_method.ne => nil, :unsubscribed.ne => true).pluck(:account_id))
  end

  def not_monthly_donors
    Account.and(:id.in => organisationships.and(monthly_donation_method: nil).pluck(:account_id))
  end

  def subscribed_not_monthly_donors
    Account.and(:id.in => organisationships.and(:monthly_donation_method => nil, :unsubscribed.ne => true).pluck(:account_id))
  end

  def facilitators
    retry_mongo_operation do
      Account.and(:id.in =>
          EventFacilitation.and(:event_id.in => events.future.pluck(:id)).pluck(:account_id) +
          Activityship.and(:activity_id.in => activities.pluck(:id), :admin => true).pluck(:account_id))
    end
  end
end
