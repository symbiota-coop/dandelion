# Helpers the organisation test files (test/organisations, and test/events for who may make events) share: members,
# local groups and importing followers
module OrganisationsHelpers
  # A new account following org, the organisationship with these attributes (admin: true, ...)
  def add_organisation_member(org, **attrs)
    account = FactoryBot.create(:account)
    account.organisationships.create!(organisation: org, unsubscribed: false, **attrs)
    account
  end

  def add_event_manager(org)
    add_organisation_member(org, event_manager: true)
  end

  # @local_group in @organisation, whose owner (@account) is an organisation admin and the group's admin
  def create_local_group(**attrs)
    create_organisation
    @local_group = FactoryBot.create(:local_group, organisation: @organisation, **attrs)
  end

  # A new account, with these attributes, following local_group, the following with following's
  def local_group_follower(local_group = @local_group, following: {}, **attrs)
    account = FactoryBot.create(:account, **attrs)
    local_group.local_groupships.create!(account: account, **following)
    account
  end

  # A CSV of followers to import, uploaded
  def csv_upload(rows)
    Rack::Test::UploadedFile.new(StringIO.new(rows), 'text/csv', original_filename: 'followers.csv')
  end
end
