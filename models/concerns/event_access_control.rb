module EventAccessControl
  extend ActiveSupport::Concern

  class_methods do
    def revenue_admin?(event, account)
      account &&
        event &&
        (
        account.admin? ||
          (event.activity && Activity.admin?(event.activity, account)) ||
          (event.local_group && LocalGroup.admin?(event.local_group, account)) ||
          (event.organisation && Organisation.admin?(event.organisation, account)) ||
          (event.cohosts.any? { |cohost| Organisation.admin?(cohost, account) })
      )
    end

    def admin?(event, account)
      account &&
        event &&
        (
        account.admin? ||
          event.account_id == account.id ||
          event.revenue_sharer_id == account.id ||
          event.organiser_id == account.id ||
          event.coordinator_id == account.id ||
          event.event_facilitations.find_by(account: account) ||
          (event.activity && Activity.admin?(event.activity, account)) ||
          (event.local_group && LocalGroup.admin?(event.local_group, account)) ||
          (event.organisation && Organisation.admin?(event.organisation, account)) ||
          (event.cohosts.any? { |cohost| Organisation.admin?(cohost, account) })
      )
    end

    def participant?(event, account)
      (account && event.tickets.complete.find_by(account: account)) || Event.admin?(event, account)
    end

    def email_viewer?(event, account)
      account && event && ((event.show_emails && Event.admin?(event, account)) || Organisation.admin?(event.organisation, account))
    end
  end
end
