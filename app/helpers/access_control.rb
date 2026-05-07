Dandelion::App.helpers do
  def viewable?(account, privacyable, viewer: current_account, viewer_in_network: nil)
    account.respond_to?(privacyable) &&
      account.send(privacyable) &&
      (viewer || !Account.sensitive?(privacyable)) &&
      (
        (viewer && viewer.admin?) ||
        account.send("#{privacyable}_privacy").nil? ||
        (account.send("#{privacyable}_privacy") == 'Public') ||
        (account.send("#{privacyable}_privacy") == 'People I follow' && (viewer_in_network || (viewer && (viewer.id == account.id || account.network.find(viewer.id))))) ||
        (account.send("#{privacyable}_privacy") == 'Only me' && viewer && viewer.id == account.id)
      )
  end

  def kick!(notice: "You don't have access to that page", redirect_url: nil, notice_type: :error)
    if request.xhr?
      halt 403
    else
      flash[notice_type] = notice
      session[:return_to] = request.url
      redirect(redirect_url || (current_account ? '/' : '/accounts/sign_in'))
    end
  end

  def admin?(account = current_account)
    account && account.admin?
  end

  def admins_only!
    kick! unless admin?
  end

  def cached_permission(cache_name, record, account)
    cache = instance_variable_get(cache_name) || instance_variable_set(cache_name, {})
    key = [record&.class&.name, record&.id&.to_s, account&.id&.to_s]
    cache.fetch(key) do
      cache[key] = yield
    end
  end

  def organisation_admin?(organisation = nil, account = current_account)
    organisation ||= @organisation
    cached_permission(:@organisation_admin_cache, organisation, account) do
      Organisation.admin?(organisation, account)
    end
  end

  def organisation_admins_only!
    kick!(redirect_url: "/o/#{@organisation.slug}") unless organisation_admin?
  end

  def organisation_admins_or_event_creators_only!
    allowed = Organisation.admin_or_event_creator?(@organisation, current_account)
    kick!(redirect_url: "/o/#{@organisation.slug}") unless allowed
  end

  def can_create_events_for_organisation?(organisation = nil, account = current_account)
    organisation ||= @organisation
    cached_permission(:@can_create_events_for_organisation_cache, organisation, account) do
      Organisation.can_create_events_for_organisation?(organisation, account)
    end
  end

  def can_create_events_for_organisation_only!
    kick!(redirect_url: "/o/#{@organisation.slug}") unless can_create_events_for_organisation?
  end

  def organisation_monthly_donor_plus?(organisation = nil, account = current_account)
    organisation ||= @organisation
    cached_permission(:@organisation_monthly_donor_plus_cache, organisation, account) do
      Organisation.monthly_donor_plus?(organisation, account)
    end
  end

  def organisation_monthly_donors_plus_only!
    kick! unless organisation_monthly_donor_plus?
  end

  def activity_admin?(activity = nil, account = current_account)
    activity ||= @activity
    cached_permission(:@activity_admin_cache, activity, account) do
      Activity.admin?(activity, account, organisation_admin: (organisation_admin?(activity.organisation, account) if activity))
    end
  end

  def activity_admins_only!
    kick!(redirect_url: "/activities/#{@activity.id}") unless activity_admin?
  end

  def local_group_admin?(local_group = nil, account = current_account)
    local_group ||= @local_group
    cached_permission(:@local_group_admin_cache, local_group, account) do
      LocalGroup.admin?(local_group, account, organisation_admin: (organisation_admin?(local_group.organisation, account) if local_group))
    end
  end

  def local_group_admins_only!
    kick!(redirect_url: "/local_groups/#{@local_group.id}") unless local_group_admin?
  end

  def event_admin?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_admin_cache, event, account) do
      Event.admin?(
        event,
        account,
        activity_admin: (activity_admin?(event.activity, account) if event&.activity),
        local_group_admin: (local_group_admin?(event.local_group, account) if event&.local_group),
        organisation_admin: (organisation_admin?(event.organisation, account) if event&.organisation)
      )
    end
  end

  def event_admins_only!
    kick!(redirect_url: "/e/#{@event.slug}") unless event_admin?
  end

  def event_revenue_admin?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_revenue_admin_cache, event, account) do
      Event.revenue_admin?(
        event,
        account,
        activity_admin: (activity_admin?(event.activity, account) if event&.activity),
        local_group_admin: (local_group_admin?(event.local_group, account) if event&.local_group),
        organisation_admin: (organisation_admin?(event.organisation, account) if event&.organisation)
      )
    end
  end

  def event_revenue_admins_only!
    kick!(redirect_url: "/e/#{@event.slug}") unless event_revenue_admin?
  end

  def event_admins_or_revenue_admins_only!
    kick!(redirect_url: "/e/#{@event.slug}") unless event_admin? || event_revenue_admin?
  end

  def event_email_viewer?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_email_viewer_cache, event, account) do
      Event.email_viewer?(
        event,
        account,
        event_admin: (event_admin?(event, account) if event&.show_emails),
        organisation_admin: (organisation_admin?(event.organisation, account) if event&.organisation)
      )
    end
  end

  def event_email_viewers_only!
    kick! unless event_email_viewer?
  end

  def event_lock_admin?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_lock_admin_cache, event, account) do
      Event.lock_admin?(
        event,
        account,
        event_admin: (event_admin?(event, account) if event && !event.organisation.allow_event_submissions?),
        event_revenue_admin: (event_revenue_admin?(event, account) if event&.organisation&.allow_event_submissions?)
      )
    end
  end

  def event_participant?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_participant_cache, event, account) do
      Event.participant?(event, account, event_admin: event_admin?(event, account))
    end
  end

  def event_participants_only!
    kick! unless event_participant?
  end

  def order_email_viewer?(order = nil, account = current_account)
    order ||= @order
    cached_permission(:@order_email_viewer_cache, order, account) do
      Order.email_viewer?(
        order,
        account,
        event_email_viewer: (event_email_viewer?(order.event, account) if order&.event),
        event_admin: (event_admin?(order.event, account) if order&.opt_in_facilitator && order.event)
      )
    end
  end

  def order_email_viewers_only!
    kick! unless order_email_viewer?
  end

  def ticket_email_viewer?(ticket = nil, account = current_account)
    ticket ||= @ticket
    cached_permission(:@ticket_email_viewer_cache, ticket, account) do
      Ticket.email_viewer?(ticket, account, order_email_viewer: (order_email_viewer?(ticket.order, account) if ticket&.order))
    end
  end

  def ticket_email_viewers_only!
    kick! unless ticket_email_viewer?
  end

  def donation_email_viewer?(donation = nil, account = current_account)
    donation ||= @donation
    cached_permission(:@donation_email_viewer_cache, donation, account) do
      Donation.email_viewer?(donation, account, order_email_viewer: (order_email_viewer?(donation.order, account) if donation&.order))
    end
  end

  def donation_email_viewers_only!
    kick! unless donation_email_viewer?
  end

  def gathering_admin?(gathering = nil, account = current_account)
    gathering ||= @gathering
    cached_permission(:@gathering_admin_cache, gathering, account) do
      Gathering.admin?(gathering, account)
    end
  end

  def gathering_admins_only!
    kick!(redirect_url: "/g/#{@gathering.slug}") unless gathering_admin?
  end

  def comment_admin?(comment = nil, account = current_account)
    comment ||= @comment
    cached_permission(:@comment_admin_cache, comment, account) do
      gathering = comment.commentable.gathering if comment && %w[Team Tactivity Mapplication].include?(comment.commentable_type)
      Comment.admin?(comment, account, gathering_admin: (gathering_admin?(gathering, account) if gathering))
    end
  end

  def comment_admins_only!
    kick! unless comment_admin?
  end

  def can_add_photo_to?(photoable, account = current_account)
    return false unless account && photoable

    case photoable
    when Gathering
      gathering_admin?(photoable, account)
    when Comment
      photoable.account_id == account.id
    when TicketType
      event_admin?(photoable.event, account)
    else
      false
    end
  end

  def sign_in_required!(notice: 'Please sign up or sign in to continue', redirect_url: '/accounts/new', notice_type: :notice)
    kick!(notice: notice, redirect_url: redirect_url, notice_type: notice_type) unless current_account
  end

  def sign_in_code_required!
    return if current_account

    if params[:account_id] && (@account = Account.find(params[:account_id]))
      @account.generate_sign_in_token!
      @account.send_sign_in_code
      kick!(notice: nil, redirect_url: "/accounts/sign_in_code?account_id=#{params[:account_id]}")
    else
      sign_in_required!
    end
  end

  def membership_required!(gathering = nil, account = current_account)
    gathering ||= @gathering
    return if account && gathering && gathering.memberships.find_by(account: account)

    kick!(
      notice: 'You must be a member of that gathering to access that page',
      redirect_url: ("/g/#{gathering.slug}" if %w[open closed].include?(gathering.privacy))
    )
  end

  def confirmed_membership_required!(gathering = nil, account = current_account)
    gathering ||= @gathering
    return if account && gathering && (membership = gathering.memberships.find_by(account: account)) && membership.confirmed?

    kick!(
      notice: (membership ? 'You must make a payment before accessing that page.' : 'You must be a member of the gathering to access that page.'),
      redirect_url: ("/g/#{gathering.slug}" if %w[open closed].include?(gathering.privacy))
    )
  end
end
