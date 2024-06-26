Dandelion::App.helpers do
  def viewable?(account, privacyable, viewer: current_account, viewer_in_network: nil)
    (
      account.respond_to?(privacyable) &&
      account.send(privacyable)) &&
      (viewer || !Account.sensitive?(privacyable)) &&
      (
        (viewer && viewer.admin?) ||
        account.send("#{privacyable}_privacy").nil? ||
        (account.send("#{privacyable}_privacy") == 'Public') ||
        (account.send("#{privacyable}_privacy") == 'People I follow' && (viewer_in_network || (viewer && (viewer.id == account.id || account.network.find(viewer.id))))) ||
        (account.send("#{privacyable}_privacy") == 'Only me' && (viewer && viewer.id == account.id))
      )
  end

  def kick!(notice: "You don't have access to that page", redirect_url: nil, notice_type: :error)
    if request.xhr?
      halt 403
    else
      flash[notice_type] = notice
      session[:return_to] = request.url
      redirect((redirect_url || (current_account ? '/' : '/accounts/sign_in')))
    end
  end

  def creator?(createable, account = current_account)
    account and createable.account and createable.account.id == account.id
  end

  def admin?(account = current_account)
    account && account.admin?
  end

  def admins_only!
    kick! unless admin?
  end

  def organisation_admin?(organisation = nil, account = current_account)
    organisation ||= @organisation
    Organisation.admin?(organisation, account)
  end

  def organisation_admins_only!
    kick!(redirect_url: "/o/#{@organisation.slug}") unless organisation_admin?
  end

  def activity_admin?(activity = nil, account = current_account)
    activity ||= @activity
    Activity.admin?(activity, account)
  end

  def activity_admins_only!
    kick!(redirect_url: "/activities/#{@activity.id}") unless activity_admin?
  end

  def local_group_admin?(local_group = nil, account = current_account)
    local_group ||= @local_group
    LocalGroup.admin?(local_group, account)
  end

  def local_group_admins_only!
    kick!(redirect_url: "/local_groups/#{@local_group.id}") unless local_group_admin?
  end

  def organisation_assistant?(organisation = nil, account = current_account)
    organisation ||= @organisation
    Organisation.assistant?(organisation, account)
  end

  def organisation_assistants_only!
    kick! unless organisation_assistant?
  end

  def organisation_monthly_donor_plus?(organisation = nil, account = current_account)
    organisation ||= @organisation
    Organisation.monthly_donor_plus?(organisation, account)
  end

  def organisation_monthly_donors_plus_only!
    kick! unless organisation_monthly_donor_plus?
  end

  def event_admin?(event = nil, account = current_account)
    event ||= @event
    Event.admin?(event, account)
  end

  def event_admins_only!
    kick!(redirect_url: "/e/#{@event.slug}") unless event_admin?
  end

  def event_revenue_admin?(event = nil, account = current_account)
    event ||= @event
    Event.revenue_admin?(event, account)
  end

  def event_revenue_admins_only!
    kick!(redirect_url: "/e/#{@event.slug}") unless event_revenue_admin?
  end

  def event_email_viewer?(event = nil, account = current_account)
    event ||= @event
    Event.email_viewer?(event, account)
  end

  def event_email_viewers_only!
    kick! unless event_email_viewer?
  end

  def order_email_viewer?(order = nil, account = current_account)
    order ||= @order
    Order.email_viewer?(order, account)
  end

  def order_email_viewers_only!
    kick! unless order_email_viewer?
  end

  def ticket_email_viewer?(ticket = nil, account = current_account)
    ticket ||= @ticket
    Ticket.email_viewer?(ticket, account)
  end

  def ticket_email_viewers_only!
    kick! unless ticket_email_viewer?
  end

  def donation_email_viewer?(donation = nil, account = current_account)
    donation ||= @donation
    Donation.email_viewer?(donation, account)
  end

  def donation_email_viewers_only!
    kick! unless donation_email_viewer?
  end

  def event_participant?(event = nil, account = current_account)
    event ||= @event
    Event.participant?(event, account)
  end

  def event_participants_only!
    kick! unless event_participant?
  end

  def gathering_admin?(gathering = nil, account = current_account)
    gathering ||= @gathering
    Gathering.admin?(gathering, account)
  end

  def gathering_admins_only!
    kick!(redirect_url: "/g/#{@gathering.slug}") unless gathering_admin?
  end

  def comment_admin?(comment = nil, account = current_account)
    comment ||= @comment
    Comment.admin?(comment, account)
  end

  def comment_admins_only!
    kick! unless comment_admin?
  end

  def sign_in_required!(notice: 'Please sign up or sign in to continue', redirect_url: '/accounts/new', notice_type: :notice)
    kick!(notice: notice, redirect_url: redirect_url, notice_type: notice_type) unless current_account
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
    return if account && gathering && ((membership = gathering.memberships.find_by(account: account)) && membership.confirmed?)

    kick!(
      notice: (membership ? 'You must make a payment before accessing that page.' : 'You must be a member of the gathering to access that page.'),
      redirect_url: ("/g/#{gathering.slug}" if %w[open closed].include?(gathering.privacy))
    )
  end
end
