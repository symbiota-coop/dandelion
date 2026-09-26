module EventAccessControl
  extend ActiveSupport::Concern

  def can_assign_activity?(account)
    return false unless activity && account

    Activity.admin?(activity, account) ||
      (organisation && activity.organisation_id == organisation.id && Organisation.admin_or_event_manager?(organisation, account))
  end

  def can_assign_local_group?(account)
    return false unless local_group && account

    LocalGroup.admin?(local_group, account) ||
      (organisation && local_group.organisation_id == organisation.id && Organisation.admin_or_event_manager?(organisation, account))
  end

  def can_bulk_update_activity_events?(account = last_saved_by)
    can_assign_activity?(account)
  end

  class_methods do
    # Who may change an event's revenue sharer and profit-share settings.
    # Unlike revenue_admin?, cohost admins are excluded: cohosts are not trusted
    # by the host organisation, so trusting them here would let them redirect
    # the host organisation's ticket revenue. This is also who may add cohosts.
    def revenue_settings_admin?(event, account, activity_admin: nil, local_group_admin: nil, organisation_admin: nil)
      account &&
        event &&
        (
          account.admin? ||
          (event.activity && (activity_admin || (activity_admin.nil? && Activity.admin?(event.activity, account)))) ||
          (event.local_group && (local_group_admin || (local_group_admin.nil? && LocalGroup.admin?(event.local_group, account)))) ||
          (event.organisation && Organisation.admin_or_event_manager?(event.organisation, account, organisation_admin: organisation_admin))
        )
    end

    def revenue_admin?(event, account, activity_admin: nil, local_group_admin: nil, organisation_admin: nil)
      revenue_settings_admin?(event, account, activity_admin: activity_admin, local_group_admin: local_group_admin, organisation_admin: organisation_admin) ||
        (account && event && event.cohosts.any? { |cohost| Organisation.admin_or_event_manager?(cohost, account) })
    end

    def admin?(event, account, activity_admin: nil, local_group_admin: nil, organisation_admin: nil)
      account &&
        event &&
        (
        account.admin? ||
          event.account_id == account.id ||
          event.revenue_sharer_id == account.id ||
          event.organiser_id == account.id ||
          event.coordinator_id == account.id ||
          event.event_facilitations.find_by(account: account) ||
          (event.activity && (activity_admin || (activity_admin.nil? && Activity.admin?(event.activity, account)))) ||
          (event.local_group && (local_group_admin || (local_group_admin.nil? && LocalGroup.admin?(event.local_group, account)))) ||
          (event.organisation && Organisation.admin_or_event_manager?(event.organisation, account, organisation_admin: organisation_admin)) ||
          event.cohosts.any? { |cohost| Organisation.admin_or_event_manager?(cohost, account) }
      )
    end

    # Query counterpart of admin?: every event the account can administer
    def administered_by(account)
      return none unless account
      return all if account.admin?

      admin_organisation_ids = Organisationship.and(account_id: account.id, admin: true).pluck(:organisation_id)
      manager_organisation_ids = admin_organisation_ids + Organisationship.and(account_id: account.id, event_manager: true).pluck(:organisation_id)
      activity_ids = Activityship.and(account_id: account.id, admin: true).pluck(:activity_id) + Activity.and(:organisation_id.in => admin_organisation_ids).pluck(:id)
      local_group_ids = LocalGroupship.and(account_id: account.id, admin: true).pluck(:local_group_id) + LocalGroup.and(:organisation_id.in => admin_organisation_ids).pluck(:id)
      event_ids = EventFacilitation.and(account_id: account.id).pluck(:event_id) + Cohostship.and(:organisation_id.in => manager_organisation_ids).pluck(:event_id)

      self.and('$or' => [
                 { account_id: account.id },
                 { revenue_sharer_id: account.id },
                 { organiser_id: account.id },
                 { coordinator_id: account.id },
                 { _id: { '$in' => event_ids } },
                 { activity_id: { '$in' => activity_ids } },
                 { local_group_id: { '$in' => local_group_ids } },
                 { organisation_id: { '$in' => manager_organisation_ids } }
               ])
    end

    def participant?(event, account, event_admin: nil)
      (account && event.tickets.complete.find_by(account: account)) || event_admin || (event_admin.nil? && Event.admin?(event, account))
    end

    def email_viewer?(event, account, event_admin: nil, organisation_admin: nil)
      account && event && (
        (event.show_emails && (event_admin || (event_admin.nil? && Event.admin?(event, account)))) ||
          (event.organisation && Organisation.admin_or_event_manager?(event.organisation, account, organisation_admin: organisation_admin)) ||
          event.cohosts.any? { |cohost| Organisation.admin_or_event_manager?(cohost, account) }
      )
    end

    def lock_admin?(event, account, event_admin: nil, event_revenue_admin: nil)
      event && event.organisation.allow_event_submissions? ? (event_revenue_admin || (event_revenue_admin.nil? && revenue_admin?(event, account))) : (event_admin || (event_admin.nil? && admin?(event, account)))
    end
  end
end
