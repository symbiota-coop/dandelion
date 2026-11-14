require_relative '../test_config'

# Starting and saving a new event: whose organisation it's for, who may, and where everyone else is sent
class EventCreationTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def new_event_params(organisation, **attrs)
    { organisation_id: organisation.id.to_s, name: 'Brand new event', location: 'Online', currency: 'GBP',
      start_time: 1.month.from_now.strftime('%Y-%m-%d %H:%M'), end_time: (1.month.from_now + 2.hours).strftime('%Y-%m-%d %H:%M') }.merge(attrs)
  end

  test "an activity's or local group's admin starts an event for its organisation" do
    covers_route 'GET /events/new'
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    activity_admin = FactoryBot.create(:account)
    activity.activityships.create!(account: activity_admin, admin: true)
    local_group_admin = FactoryBot.create(:account)
    local_group.local_groupships.create!(account: local_group_admin, admin: true)

    sign_in_with_rack(activity_admin)
    get '/events/new', activity_id: activity.id.to_s
    assert_equal 200, last_response.status
    assert_includes last_response.body, %(value="#{@organisation.id}")
    assert_includes last_response.body, %(href="#{activity.path}")

    sign_in_with_rack(local_group_admin)
    get '/events/new', local_group_id: local_group.id.to_s
    assert_equal 200, last_response.status
    assert_includes last_response.body, %(value="#{@organisation.id}")
    assert_includes last_response.body, %(href="#{local_group.path}")
  end

  test "an activity or local group that doesn't exist is not found" do
    create_organisation
    sign_in_with_rack(@account)

    get '/events/new', activity_id: BSON::ObjectId.new.to_s
    assert_equal 404, last_response.status
    get '/events/new', local_group_id: BSON::ObjectId.new.to_s
    assert_equal 404, last_response.status
    get '/events/new', organisation_id: BSON::ObjectId.new.to_s
    assert_equal 404, last_response.status
  end

  test "someone who can't create events for an organisation isn't offered it" do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    follower = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: follower)
    activity.activityships.create!(account: follower)
    # So the organisation's page has its events block for everyone
    create_event

    sign_in(follower)
    visit "/o/#{@organisation.slug}"
    # The events block is a pagelet: wait for it before checking what it leaves out
    assert page.has_link?('All events', href: "/o/#{@organisation.slug}/events")
    assert page.has_no_link?(href: "/events/new?organisation_id=#{@organisation.id}")
    visit activity.path
    assert page.has_link?('All events')
    assert page.has_no_link?('Create an event')

    sign_in(@account)
    visit activity.path
    assert page.has_link?('Create an event', href: "/events/new?activity_id=#{activity.id}")
    visit "/o/#{@organisation.slug}"
    assert page.has_link?('Create an event', href: "/events/new?organisation_id=#{@organisation.id}")
  end

  test "someone who can't create events for an organisation is refused, and makes none" do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    other = FactoryBot.create(:account)
    FactoryBot.create(:organisation, account: other)
    sign_in_with_rack(other)

    [{ organisation_id: @organisation.id.to_s }, { activity_id: activity.id.to_s }].each do |query|
      get '/events/new', query
      assert_redirected_to '/events'
      follow_redirect!
      assert_includes last_response.body, "permission to create events for this organisation"
    end

    assert_no_difference -> { Event.count } do
      post '/events/new', event: new_event_params(@organisation)
    end
    assert_redirected_to '/events'
    follow_redirect!
    assert_includes last_response.body, "permission to create events for this organisation"

    # Taking event submissions, it may: locked, for the organisation to review
    @organisation.update!(allow_event_submissions: true)
    assert_difference -> { Event.count }, 1 do
      post '/events/new', event: new_event_params(@organisation)
    end
    event = Event.find_by(name: 'Brand new event')
    assert_redirected_to "/e/#{event.slug}"
    assert_equal @organisation, event.organisation
    assert event.locked?
  end

  test "an organisation's admin creates an event, and a save that fails makes nothing and says why" do
    create_organisation
    sign_in_with_rack(@account)

    assert_no_difference -> { Event.count } do
      post '/events/new', event: new_event_params(@organisation, name: '')
    end
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'There was an error saving the event'
    assert_includes last_response.body, %(action="/events/new")

    assert_difference -> { Event.count }, 1 do
      post '/events/new', event: new_event_params(@organisation)
    end
    event = Event.find_by(name: 'Brand new event')
    assert_redirected_to "/e/#{event.slug}"
    assert_equal @organisation, event.organisation
    assert_equal @account, event.account
    refute event.locked?
  end

  test "someone who can't create events for any organisation is sent to make one" do
    create_organisation
    newcomer = FactoryBot.create(:account)
    sign_in_with_rack(newcomer)

    get '/events/new'
    assert_redirected_to '/o/new'
    assert_no_difference -> { Event.count } do
      post '/events/new', event: new_event_params(@organisation, organisation_id: '')
    end
    assert_redirected_to '/o/new'

    # Someone who can create events for one, but named none, is sent to the listings to pick one
    sign_in_with_rack(@account)
    get '/events/new'
    assert_redirected_to '/events'
    post '/events/new', event: new_event_params(@organisation, organisation_id: '')
    assert_redirected_to '/events'
  end

  test 'an organisation asked to contribute is sent to contribute first, and back' do
    create_organisation(stripe_client_id: 'ca_test')
    @organisation.set(paid_up: false)
    sign_in_with_rack(@account)

    get '/events/new', organisation_id: @organisation.id.to_s
    assert_redirected_to "/o/#{@organisation.slug}/contribute"
    return_to = Rack::Utils.parse_query(URI(last_response.location).query)['return_to']
    assert_equal "/events/new?organisation_id=#{@organisation.id}", return_to

    get '/events/new', organisation_id: @organisation.id.to_s, contribution_skipped: 1
    assert_equal 200, last_response.status
    assert_includes last_response.body, %(action="/events/new")

    @organisation.set(paid_up: true)
    get '/events/new', organisation_id: @organisation.id.to_s
    assert_equal 200, last_response.status
  end
end
