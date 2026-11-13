# Helpers the organisation test files (test/organisations) share: local groups and importing followers
module OrganisationsHelpers
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
