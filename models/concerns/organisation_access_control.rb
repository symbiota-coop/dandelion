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

    def can_create_events_for_organisation?(organisation, account)
      return false unless account && organisation

      return true if account.admin?

      organisation.organisationships.and(account: account).and('$or' => [{ admin: true }, { event_creator: true }]).exists? ||
        Activityship.and(account: account, admin: true, :activity_id.in => organisation.activities.pluck(:id)).exists? ||
        LocalGroupship.and(account: account, admin: true, :local_group_id.in => organisation.local_groups.pluck(:id)).exists?
    end

    def monthly_donor_plus?(organisation, account)
      account && organisation && (Organisation.admin?(organisation, account) || organisation.organisationships.find_by(:account => account, :monthly_donation_method.ne => nil))
    end
  end
end
