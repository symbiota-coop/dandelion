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

    def assistant?(organisation, account)
      account && organisation && (Organisation.admin?(organisation, account) or organisation.local_groups.any? { |local_group| LocalGroup.admin?(local_group, account) } or organisation.activities.any? { |activity| Activity.admin?(activity, account) })
    end

    def monthly_donor_plus?(organisation, account)
      account && organisation && (Organisation.admin?(organisation, account) || organisation.organisationships.find_by(:account => account, :monthly_donation_method.ne => nil))
    end
  end
end
