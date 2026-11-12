Dandelion::App.helpers do
  def viewable?(account, privacyable, viewer: current_account, viewer_in_network: nil)
    return false unless account.respond_to?(privacyable) && account.send(privacyable) && (viewer || !Account.sensitive?(privacyable))
    return true if viewer && viewer.admin?

    case account.privacy_level(privacyable)
    when 'Public' then true
    when 'People I follow' then viewer_in_network || (viewer && (viewer.id == account.id || account.network.find(viewer.id)))
    when 'Only me' then viewer && viewer.id == account.id
    end
  end

  # A private profile (Account#private?) is visible only to its own account, and so are the lists on it
  def profile_viewable?(account)
    !account.private? || own_account?(account)
  end

  # What an account shows even before it signs in, like its feedback as a facilitator and the embeds of it, is refused
  # only when the account chose to hide its profile (hidden), not when it counts as private for never having signed in
  def profile_not_hidden?(account)
    !account.hidden? || own_account?(account)
  end

  def own_account?(account)
    current_account && current_account.id == account.id
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

  def organisation_admins_or_event_managers?(organisation = nil, account = current_account)
    organisation ||= @organisation
    cached_permission(:@organisation_admins_or_event_managers_cache, organisation, account) do
      Organisation.admin_or_event_manager?(organisation, account)
    end
  end

  def organisation_admins_or_event_managers_only!
    allowed = organisation_admins_or_event_managers?
    kick!(redirect_url: "/o/#{@organisation.slug}") unless allowed
  end

  def can_create_events_for_organisation?(organisation = nil, account = current_account)
    organisation ||= @organisation
    cached_permission(:@can_create_events_for_organisation_cache, organisation, account) do
      Organisation.can_create_events_for_organisation?(organisation, account)
    end
  end

  def activity_admin?(activity = nil, account = current_account)
    activity ||= @activity
    cached_permission(:@activity_admin_cache, activity, account) do
      Activity.admin?(activity, account, organisation_admin: (organisation_admin?(activity.organisation, account) if activity))
    end
  end

  def activity_admins_only!
    kick!(redirect_url: @activity.path) unless activity_admin?
  end

  def local_group_admin?(local_group = nil, account = current_account)
    local_group ||= @local_group
    cached_permission(:@local_group_admin_cache, local_group, account) do
      LocalGroup.admin?(local_group, account, organisation_admin: (organisation_admin?(local_group.organisation, account) if local_group))
    end
  end

  def local_group_admins_only!
    kick!(redirect_url: @local_group.path) unless local_group_admin?
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

  def can_delete_event?(event = nil, account = current_account)
    event ||= @event
    return false unless event && account

    cached_permission(:@can_delete_event_cache, event, account) do
      if organisation_admin?(event.organisation, account)
        true
      else
        event.account_id == account.id && (
          organisation_admins_or_event_managers?(event.organisation, account) ||
          event.cohosts.any? { |cohost| organisation_admins_or_event_managers?(cohost, account) }
        )
      end
    end
  end

  def can_delete_event_only!
    kick!(redirect_url: "/e/#{@event.slug}") unless can_delete_event?
  end

  # Admins and event managers of an event's organisation are revenue admins of it, so that's checked first, once per
  # organisation: otherwise each of an organisation's events costs several queries (its activity, local group and
  # organisation, and the event manager check), which made /o/:slug/events/stats take seconds for event managers
  def event_organisation_admin_or_event_manager?(event, account = current_account)
    return false unless event&.organisation_id && account

    cache = @event_organisation_admin_or_event_manager_cache ||= {}
    key = [event.organisation_id.to_s, account.id.to_s]
    cache.fetch(key) do
      # organisation_admins_or_event_managers? falls back to @organisation when given nil
      cache[key] = (organisation = event.organisation) && organisation_admins_or_event_managers?(organisation, account) ? true : false
    end
  end

  def event_revenue_admin?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_revenue_admin_cache, event, account) do
      next true if event_organisation_admin_or_event_manager?(event, account)

      Event.revenue_admin?(
        event,
        account,
        activity_admin: (activity_admin?(event.activity, account) if event&.activity),
        local_group_admin: (local_group_admin?(event.local_group, account) if event&.local_group),
        organisation_admin: (organisation_admin?(event.organisation, account) if event&.organisation)
      )
    end
  end

  def event_revenue_settings_admin?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_revenue_settings_admin_cache, event, account) do
      Event.revenue_settings_admin?(
        event,
        account,
        activity_admin: (activity_admin?(event.activity, account) if event&.activity),
        local_group_admin: (local_group_admin?(event.local_group, account) if event&.local_group),
        organisation_admin: (organisation_admin?(event.organisation, account) if event&.organisation)
      )
    end
  end

  def event_cohost_adder?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_cohost_adder_cache, event, account) do
      Event.cohost_adder?(
        event,
        account,
        organisation_admin: (organisation_admin?(event.organisation, account) if event&.organisation)
      )
    end
  end

  def event_cohost_remover?(event = nil, account = current_account)
    event ||= @event
    cached_permission(:@event_cohost_remover_cache, event, account) do
      Event.cohost_remover?(
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

  def order_email_viewer?(order = nil, account = current_account)
    order ||= @order
    cached_permission(:@order_email_viewer_cache, order, account) do
      # Use @event when it's the order's event: an order loaded through a ticket (as on /e/:slug/tickets) would otherwise load it again
      event = order && (@event && order.event_id == @event.id ? @event : order.event)
      Order.email_viewer?(
        order,
        account,
        event_email_viewer: (event_email_viewer?(event, account) if event),
        event_admin: (event_admin?(event, account) if order&.opt_in_facilitator && event)
      )
    end
  end

  def ticket_email_viewer?(ticket = nil, account = current_account)
    ticket ||= @ticket
    cached_permission(:@ticket_email_viewer_cache, ticket, account) do
      Ticket.email_viewer?(ticket, account, order_email_viewer: (order_email_viewer?(ticket.order, account) if ticket&.order))
    end
  end

  def donation_email_viewer?(donation = nil, account = current_account)
    donation ||= @donation
    cached_permission(:@donation_email_viewer_cache, donation, account) do
      Donation.email_viewer?(donation, account, order_email_viewer: (order_email_viewer?(donation.order, account) if donation&.order))
    end
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

  # For a gathering record that's someone's own (a shift, teamship or optionship): refuses anyone but them and the
  # gathering's admins
  def own_or_gathering_admins_only!(record)
    halt 403 unless (current_account && record.account_id == current_account.id) || gathering_admin?
  end

  def comment_admin?(comment = nil, account = current_account)
    comment ||= @comment
    cached_permission(:@comment_admin_cache, comment, account) do
      gathering = comment.commentable.gathering if comment && %w[Team Tactivity Mapplication].include?(comment.commentable_type)
      Comment.admin?(comment, account, gathering_admin: (gathering_admin?(gathering, account) if gathering))
    end
  end

  def commentable_viewer?(commentable = nil, account = current_account)
    commentable ||= @commentable
    cached_permission(:@commentable_viewer_cache, commentable, account) do
      Post.viewer?(
        commentable,
        account,
        event_participant: (event_participant?(commentable, account) if commentable.is_a?(Event)),
        activity_admin: (activity_admin?(commentable.activity, account) if commentable.is_a?(ActivityApplication))
      )
    end
  end

  def commentable_viewers_only!
    kick! unless commentable_viewer?
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
      @account.send_sign_in_code
      kick!(notice: nil, redirect_url: "/accounts/sign_in_code?account_id=#{params[:account_id]}")
    else
      sign_in_required!
    end
  end

  # Site admins can browse (GET) a gathering's pages without being a member, but not act in it. Pass
  # site_admins: false for a GET that acts on the viewer's own membership
  def site_admin_browsing_gathering?(gathering, account, site_admins: true)
    site_admins && gathering && request.get? && admin?(account)
  end

  # The account's membership of the gathering, kept in @membership when it's the viewer's of @gathering, so a route that
  # checks membership needn't look it up again
  def find_membership(gathering, account)
    membership = gathering.memberships.find_by(account: account) if account && gathering
    @membership = membership if gathering && gathering == @gathering && account == current_account
    membership
  end

  def membership_required!(gathering = nil, account = current_account, site_admins: true)
    gathering ||= @gathering
    return if find_membership(gathering, account)
    return if site_admin_browsing_gathering?(gathering, account, site_admins: site_admins)

    kick!(
      notice: 'You must be a member of that gathering to access that page',
      redirect_url: ("/g/#{gathering.slug}" if %w[open closed].include?(gathering.privacy))
    )
  end

  def confirmed_membership_required!(gathering = nil, account = current_account, site_admins: true)
    gathering ||= @gathering
    membership = find_membership(gathering, account)
    return if membership&.confirmed?
    return if !membership && site_admin_browsing_gathering?(gathering, account, site_admins: site_admins)

    kick!(
      notice: (membership ? 'You must make a payment before accessing that page.' : 'You must be a member of the gathering to access that page.'),
      redirect_url: ("/g/#{gathering.slug}" if %w[open closed].include?(gathering.privacy))
    )
  end
end
