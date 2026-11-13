# A subgroup of an organisation (Activity, LocalGroup), whose followers are its subgroupships (Activityship,
# LocalGroupship: see Subgroupship). The model includes this after CoreExtensions, and declares its own associations
# and path
module Subgroup
  extend ActiveSupport::Concern

  included do
    include SlugLookup
    include ImportFromCsv
    include SendFollowersCsv
    include Searchable

    validates_presence_of :name, :slug
    validates_uniqueness_of :slug, scope: :organisation_id
    validates_format_of :slug, with: /\A[a-z0-9-]+\z/

    before_validation do
      errors.add(:organisation, 'cannot be changed') if persisted? && organisation_id_changed?
      errors.add(:account, 'cannot be changed') if persisted? && account_id_changed?
    end
  end

  class_methods do
    def search_fields
      %w[name slug]
    end

    # Its Atlas Search index maps name and slug as autocomplete too, so searches match the start of a word in them (Searchable)
    def autocomplete_fields
      %w[name slug]
    end

    def admin?(subgroup, account, organisation_admin: nil)
      account && subgroup &&
        (
          account.admin? ||
          organisation_admin ||
          subgroup.subgroupships.find_by(account: account, admin: true) ||
          (organisation_admin.nil? && Organisation.admin?(subgroup.organisation, account))
        )
    end
  end

  # activityship or local_groupship, as its params, routes and partials name one
  def subgroupship_name
    "#{self.class.model_name.singular}ship"
  end

  # :activityships or :local_groupships
  def subgroupships_name
    :"#{subgroupship_name}s"
  end

  def subgroupships
    public_send(subgroupships_name)
  end

  # What messages call it: activity, local group
  def kind_name
    self.class.model_name.human.downcase
  end

  def pmails_including_events
    Pmail.and(:id.in => pmails_as_mailable.pluck(:id) + Pmail.and(:mailable_type => 'Event', :mailable_id.in => events.pluck(:id)).pluck(:id))
  end

  def event_tags
    EventTag.and(:id.in => EventTagship.and(:event_id.in => events.pluck(:id)).pluck(:event_tag_id))
  end

  # Members subscribed to the subgroup AND subscribed to the organisation AND not globally unsubscribed
  def subscribed_accounts
    subscribed_members.and(subscribed_organisation_ids_cache: organisation_id, unsubscribed: false)
  end
end
