module OrganisationAccessControl
  extend ActiveSupport::Concern

  class_methods do
    def admin?(organisation, account)
      account && organisation &&
        (
          account.admin? ||
          organisation.organisationships.find_by(account: account, admin: true)
        )
    end

    # Query counterpart of admin?: every organisation the account can administer
    def administered_by(account)
      return none unless account
      return all if account.admin?

      self.and(:id.in => Organisationship.and(account_id: account.id, admin: true).pluck(:organisation_id))
    end

    def admin_or_event_manager?(organisation, account, organisation_admin: nil)
      organisation_admin ||
        (organisation_admin.nil? && admin?(organisation, account)) ||
        (account && organisation && organisation.organisationships.find_by(account: account, event_manager: true))
    end

    def can_create_events_for_organisation?(organisation, account)
      return false unless account && organisation

      return true if admin_or_event_manager?(organisation, account)

      Activityship.and(account: account, admin: true, :activity_id.in => organisation.activities.pluck(:id)).exists? ||
        LocalGroupship.and(account: account, admin: true, :local_group_id.in => organisation.local_groups.pluck(:id)).exists?
    end

    def monthly_donor_plus?(organisation, account)
      account && organisation && (Organisation.admin?(organisation, account) || organisation.organisationships.find_by(:account => account, :monthly_donation_method.ne => nil))
    end
  end
end
