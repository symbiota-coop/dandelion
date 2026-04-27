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

      Organisation.admin?(organisation, account) ||
        organisation.local_groups.any? { |local_group| LocalGroup.admin?(local_group, account) } ||
        organisation.activities.any? { |activity| Activity.admin?(activity, account) } ||
        organisation.organisationships.find_by(account: account, event_creator: true)
    end

    def monthly_donor_plus?(organisation, account)
      account && organisation && (Organisation.admin?(organisation, account) || organisation.organisationships.find_by(:account => account, :monthly_donation_method.ne => nil))
    end
  end
end
