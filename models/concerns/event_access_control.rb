module EventAccessControl
  extend ActiveSupport::Concern

  class_methods do
    def revenue_admin?(event, account, activity_admin: nil, local_group_admin: nil, organisation_admin: nil)
      account &&
        event &&
        (
          account.admin? ||
          (event.activity && (activity_admin || (activity_admin.nil? && Activity.admin?(event.activity, account)))) ||
          (event.local_group && (local_group_admin || (local_group_admin.nil? && LocalGroup.admin?(event.local_group, account)))) ||
          (event.organisation && Organisation.admin_or_event_creator?(event.organisation, account, organisation_admin: organisation_admin)) ||
          event.cohosts.any? { |cohost| Organisation.admin_or_event_creator?(cohost, account) }
      )
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
          (event.organisation && Organisation.admin_or_event_creator?(event.organisation, account, organisation_admin: organisation_admin)) ||
          event.cohosts.any? { |cohost| Organisation.admin_or_event_creator?(cohost, account) }
      )
    end

    def participant?(event, account, event_admin: nil)
      (account && event.tickets.complete.find_by(account: account)) || event_admin || (event_admin.nil? && Event.admin?(event, account))
    end

    def email_viewer?(event, account, event_admin: nil, organisation_admin: nil)
      account && event && (
        (event.show_emails && (event_admin || (event_admin.nil? && Event.admin?(event, account)))) ||
          organisation_admin ||
          (organisation_admin.nil? && Organisation.admin?(event.organisation, account))
      )
    end

    def lock_admin?(event, account, event_admin: nil, event_revenue_admin: nil)
      event && event.organisation.allow_event_submissions? ? (event_revenue_admin || (event_revenue_admin.nil? && revenue_admin?(event, account))) : (event_admin || (event_admin.nil? && admin?(event, account)))
    end
  end
end
