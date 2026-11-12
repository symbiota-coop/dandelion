require_relative '../test_config'

# Events published to Bluesky/ATProto as community.lexicon.calendar.event records (EventAtproto), under the
# organisation's own account once it connects one (OrganisationAtproto, /o/:slug/atproto/connect) or else Dandelion's
# (ATPROTO_HANDLE). No network: AtprotoClient.new gives a FakeAtprotoClient for the credentials it's given
class IntegrationsAtprotoEventsTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  COLLECTION = EventAtproto::ATPROTO_COLLECTION
  ORGANISATION_DID = 'did:plc:organisation'.freeze
  DANDELION_DID = 'did:plc:dandelion'.freeze

  # Records what's asked of the repo of one account, and fails the next calls when told to
  class FakeAtprotoClient
    attr_reader :did, :session_handle, :calls
    attr_accessor :records, :failure

    def initialize(did:, handle:)
      @did = did
      @session_handle = handle
      @calls = []
      @records = []
      @rkeys = 0
    end

    def create_record(collection:, record:)
      call(:create, collection: collection, record: record)
      { 'uri' => "at://#{did}/#{collection}/rkey#{@rkeys += 1}" }
    end

    def put_record(uri:, record:)
      call(:put, uri: uri, record: record)
    end

    def delete_record(uri:)
      call(:delete, uri: uri)
    end

    def list_records(collection:, repo:)
      raise ArgumentError unless collection == COLLECTION && repo == did

      records
    end

    def actions = calls.map(&:first)

    def uris(action) = calls.filter_map { |called, args| args[:uri] if called == action }

    private

    def call(action, **args)
      raise failure if failure

      @calls << [action, args]
      {}
    end
  end

  def organisation_client
    @organisation_client ||= FakeAtprotoClient.new(did: ORGANISATION_DID, handle: 'organisation.test')
  end

  def dandelion_client
    @dandelion_client ||= FakeAtprotoClient.new(did: DANDELION_DID, handle: 'dandelion.test')
  end

  def other_client
    @other_client ||= FakeAtprotoClient.new(did: 'did:plc:other', handle: 'other.test')
  end

  # AtprotoClient.new with an organisation's handle and app password gives that account's client, and with neither
  # (as Event#atproto_client_for_publishing and the nightly tasks call it) Dandelion's, from ATPROTO_HANDLE. Anything
  # else is a sign-in Bluesky would refuse
  def with_atproto(&)
    clients = {
      %w[organisation.test organisation-password] => organisation_client,
      %w[other.test other-password] => other_client,
      [nil, nil] => dandelion_client
    }
    new_client = lambda do |handle: nil, app_password: nil|
      clients.fetch([handle, app_password]) { raise Faraday::UnauthorizedError, 'Invalid identifier or password' }
    end
    AtprotoClient.stub(:new, new_client, &)
  end

  def with_dandelion_account(&)
    with_env('ATPROTO_HANDLE' => 'dandelion.test', 'ATPROTO_APP_PASSWORD' => 'dandelion-password', 'ATPROTO_DID' => DANDELION_DID, &)
  end

  def connected_organisation(**attrs)
    create_organisation(atproto_handle: 'organisation.test', atproto_app_password: 'organisation-password', atproto_did: ORGANISATION_DID, **attrs)
  end

  # Runs the queued jobs as the worker would, loading each event afresh, until none are left
  def run_jobs
    while (job = Delayed::Job.first)
      job.invoke_job
      job.destroy
    end
  end

  # The queued jobs that would publish, update or delete a record
  def atproto_jobs
    Delayed::Job.all.select { |job| job.handler.match?(/^method_name: :\w*atproto/) }
  end

  # The exceptions ErrorReporting would send to Sentry while the block runs
  def reported_exceptions(&)
    reported = []
    ErrorReporting.stub(:capture_exception, ->(exception, **) { reported << exception }, &)
    reported
  end

  def published_event(**attrs)
    connected_organisation unless @organisation
    with_atproto do
      create_event(**attrs)
      run_jobs
    end
    @event.reload
  end

  # What gets published

  test "a public event of a connected organisation is published to the organisation's own repo, with its title, times, place and link" do
    connected_organisation
    with_atproto do
      create_event(name: 'Full moon circle', time_zone: 'America/New_York', start_time: Time.utc(2030, 6, 1, 18, 30), end_time: Time.utc(2030, 6, 1, 21),
                   description: '<p>Bring&nbsp;a <strong>blanket</strong></p>', facebook_event_url: 'https://www.facebook.com/events/123')
      assert_equal [], organisation_client.calls, 'published by a job, not while saving'
      assert_equal 1, atproto_jobs.length
      run_jobs
    end

    assert_equal [:create], organisation_client.actions
    assert_equal [], dandelion_client.calls
    _, args = organisation_client.calls.first
    assert_equal COLLECTION, args[:collection]
    assert_equal({
                   '$type' => COLLECTION,
                   'name' => 'Full moon circle',
                   'createdAt' => @event.created_at.utc.iso8601,
                   'description' => 'Bring a **blanket**',
                   'startsAt' => '2030-06-01T18:30:00Z',
                   'endsAt' => '2030-06-01T21:00:00Z',
                   'mode' => 'community.lexicon.calendar.event#inperson',
                   'status' => 'community.lexicon.calendar.event#scheduled',
                   'locations' => [{ '$type' => 'community.lexicon.location.geo', 'latitude' => '59.3251', 'longitude' => '18.0685', 'name' => '111 28, Sweden' }],
                   'uris' => [
                     { '$type' => 'community.lexicon.calendar.event#uri', 'uri' => "#{ENV['BASE_URI']}/e/#{@event.slug}", 'name' => 'Full moon circle' },
                     { '$type' => 'community.lexicon.calendar.event#uri', 'uri' => 'https://www.facebook.com/events/123', 'name' => 'Facebook event' }
                   ]
                 }, args[:record])
    assert_equal "at://#{ORGANISATION_DID}/#{COLLECTION}/rkey1", @event.reload.atproto_uri
  end

  test 'an event in a time zone is published at the same instants, in UTC' do
    start_time = ActiveSupport::TimeZone['Asia/Tokyo'].local(2030, 3, 10, 9)
    published_event(time_zone: 'Asia/Tokyo', start_time: start_time, end_time: start_time + 2.hours)

    record = organisation_client.calls.first.last[:record]
    assert_equal '2030-03-10T00:00:00Z', record['startsAt']
    assert_equal '2030-03-10T02:00:00Z', record['endsAt']
  end

  test 'an online event is published as virtual, with no place, and an event with no description has none' do
    published_event(location: 'Online', description: nil)

    record = organisation_client.calls.first.last[:record]
    assert_equal 'community.lexicon.calendar.event#virtual', record['mode']
    refute record.key?('locations')
    refute record.key?('description')
    assert_equal 1, record['uris'].length
  end

  test 'secret and locked events are never published' do
    connected_organisation
    with_atproto do
      create_event(secret: true, as: :secret_event)
      create_event(locked: true, as: :locked_event)
      assert_equal [], atproto_jobs
      run_jobs
    end

    assert_equal [], organisation_client.calls
    assert_nil @secret_event.reload.atproto_uri
    assert_nil @locked_event.reload.atproto_uri
  end

  test "an event of an organisation that hasn't connected an account isn't published when Dandelion has no account of its own" do
    create_organisation
    with_atproto do
      create_event
      run_jobs
    end

    assert_equal [], dandelion_client.calls
    assert_nil @event.reload.atproto_uri
  end

  test "an event of an organisation that hasn't connected an account is published under Dandelion's account when it has one" do
    create_organisation
    with_dandelion_account do
      with_atproto do
        create_event
        run_jobs
      end
    end

    assert_equal [:create], dandelion_client.actions
    assert_equal "at://#{DANDELION_DID}/#{COLLECTION}/rkey1", @event.reload.atproto_uri
  end

  # Updates

  test "editing a published event's details puts the same record again rather than creating another" do
    published_event
    uri = @event.atproto_uri
    with_atproto do
      @event.update_attributes!(name: 'Renamed event', location: 'Online')
      run_jobs
    end

    assert_equal %i[create put], organisation_client.actions
    _, args = organisation_client.calls.last
    assert_equal uri, args[:uri]
    assert_equal 'Renamed event', args[:record]['name']
    assert_equal 'community.lexicon.calendar.event#virtual', args[:record]['mode']
    assert_equal uri, @event.reload.atproto_uri
  end

  test "editing what isn't published (the capacity, notes) sends nothing" do
    published_event
    with_atproto do
      @event.update_attributes!(capacity: 10, notes: 'Bring keys')
      assert_equal [], atproto_jobs
    end

    assert_equal [:create], organisation_client.actions
  end

  test 'making a published event secret deletes its record, and making it public again publishes a new one' do
    published_event
    uri = @event.atproto_uri
    with_atproto do
      @event.update_attributes!(secret: true)
      run_jobs
      assert_nil @event.reload.atproto_uri
      assert_equal [:delete, { uri: uri }], organisation_client.calls.last

      @event.update_attributes!(name: 'Still secret')
      run_jobs
      assert_equal %i[create delete], organisation_client.actions, 'a secret event is not put back by editing it'

      @event.update_attributes!(secret: false)
      run_jobs
    end

    assert_equal %i[create delete create], organisation_client.actions
    assert_equal 'Still secret', organisation_client.calls.last.last[:record]['name']
    assert_equal "at://#{ORGANISATION_DID}/#{COLLECTION}/rkey2", @event.reload.atproto_uri
  end

  test 'locking a published event deletes its record' do
    published_event
    uri = @event.atproto_uri
    with_atproto do
      @event.update_attributes!(locked: true)
      run_jobs
    end

    assert_equal [:delete, { uri: uri }], organisation_client.calls.last
    assert_nil @event.reload.atproto_uri
  end

  test "a network failure when publishing is reported, doesn't stop the event saving, and the nightly sync publishes it" do
    connected_organisation
    organisation_client.failure = Faraday::ConnectionFailed.new('Connection refused')
    reported = reported_exceptions do
      with_atproto do
        create_event
        run_jobs
      end
    end

    assert @event.reload.persisted?
    assert_nil @event.atproto_uri
    assert_equal [Faraday::ConnectionFailed], reported.map(&:class)

    organisation_client.failure = nil
    with_atproto do
      results = Event.sync_atproto(hours: 1)
      assert_equal 1, results[:published]
    end
    assert_equal [:create], organisation_client.actions
    assert_equal "at://#{ORGANISATION_DID}/#{COLLECTION}/rkey1", @event.reload.atproto_uri
  end

  test "a network failure when updating is reported and keeps the event's record" do
    published_event
    uri = @event.atproto_uri
    organisation_client.failure = Faraday::ServerError.new('Bad gateway')
    reported = reported_exceptions do
      with_atproto do
        @event.update_attributes!(name: 'Renamed event')
        run_jobs
      end
    end

    assert_equal 'Renamed event', @event.reload.name
    assert_equal uri, @event.atproto_uri
    assert_equal [Faraday::ServerError], reported.map(&:class)
  end

  # Whose account

  test "a record in another account's repo is never touched with the organisation's account, nor one that isn't a calendar event" do
    published_event
    with_dandelion_account do
      with_atproto do
        @event.set(atproto_uri: "at://did:plc:other/#{COLLECTION}/rkey9")
        @event.update_attributes!(name: 'Renamed event')
        run_jobs

        @event.set(atproto_uri: "at://#{ORGANISATION_DID}/app.bsky.feed.post/rkey1")
        @event.update_attributes!(secret: true)
        run_jobs
      end
    end

    assert_equal [:create], organisation_client.actions
    assert_equal [], dandelion_client.calls
    assert_equal [], other_client.calls
  end

  test "a record published under Dandelion's account before the organisation connected its own is updated under Dandelion's" do
    create_organisation
    with_dandelion_account do
      with_atproto do
        create_event
        run_jobs
        @organisation.set(atproto_handle: 'organisation.test', atproto_app_password: 'organisation-password', atproto_did: ORGANISATION_DID)
        Event.find(@event.id).update_attributes!(name: 'Renamed event')
        run_jobs
      end
    end

    assert_equal %i[create put], dandelion_client.actions
    assert_equal [], organisation_client.calls
  end

  test "each organisation's events are published with its own account" do
    connected_organisation
    other_organisation = FactoryBot.create(:organisation, atproto_handle: 'other.test', atproto_app_password: 'other-password', atproto_did: 'did:plc:other')
    with_atproto do
      create_event
      FactoryBot.create(:event, organisation: other_organisation)
      run_jobs
    end

    assert_equal [:create], organisation_client.actions
    assert_equal [:create], other_client.actions
  end

  # The nightly sync and check

  test 'the nightly sync publishes, updates and deletes recently changed events as each should be, and a dry run sends nothing' do
    connected_organisation
    with_atproto do
      create_event(as: :unpublished_event)
      create_event(as: :published_event)
      create_event(as: :secret_event)
      Delayed::Job.delete_all
      @published_event.set(atproto_uri: "at://#{ORGANISATION_DID}/#{COLLECTION}/published")
      @secret_event.set(secret: true, atproto_uri: "at://#{ORGANISATION_DID}/#{COLLECTION}/secret")

      dry_run = Event.sync_atproto(hours: 1, dry_run: true)
      assert_equal({ published: 1, updated: 1, deleted: 1, skipped: 0, errors: [], dry_run: true }, dry_run)
      assert_equal [], organisation_client.calls

      Event.sync_atproto(hours: 1)
    end

    assert_equal %i[create delete put], organisation_client.actions.sort
    assert @unpublished_event.reload.atproto_uri
    assert_nil @secret_event.reload.atproto_uri
  end

  test "the nightly check of Dandelion's collection deletes records with no event or a secret one, updates stale ones and republishes missing ones" do
    create_organisation
    with_dandelion_account do
      with_atproto do
        create_event(as: :stale_event)
        create_event(as: :missing_event)
        create_event(as: :secret_event)
        create_event(as: :valid_event)
        Delayed::Job.delete_all
        @stale_event.set(atproto_uri: "at://#{DANDELION_DID}/#{COLLECTION}/stale")
        @missing_event.set(atproto_uri: "at://#{DANDELION_DID}/#{COLLECTION}/missing")
        @secret_event.set(secret: true, atproto_uri: "at://#{DANDELION_DID}/#{COLLECTION}/secret")
        @valid_event.set(atproto_uri: "at://#{DANDELION_DID}/#{COLLECTION}/valid")
        dandelion_client.records = [
          { 'uri' => "at://#{DANDELION_DID}/#{COLLECTION}/orphan", 'value' => { 'name' => 'Gone' } },
          { 'uri' => @stale_event.atproto_uri, 'value' => @stale_event.build_atproto_record.merge('name' => 'Old name') },
          { 'uri' => @secret_event.atproto_uri, 'value' => @secret_event.build_atproto_record },
          { 'uri' => @valid_event.atproto_uri, 'value' => @valid_event.reload.build_atproto_record }
        ]

        results = Event.verify_atproto_collection(fix: true)
        assert_equal({ total_remote: 4, total_local: 4, valid: 1, orphaned: 2, missing: 1, stale: 1, errors: 0 }, results[:summary])
      end
    end

    assert_equal ["at://#{DANDELION_DID}/#{COLLECTION}/orphan", "at://#{DANDELION_DID}/#{COLLECTION}/secret"], dandelion_client.uris(:delete)
    assert_equal [@stale_event.atproto_uri], dandelion_client.uris(:put)
    assert_equal 1, dandelion_client.actions.count(:create)
    assert_nil @secret_event.reload.atproto_uri
    assert_equal "at://#{DANDELION_DID}/#{COLLECTION}/rkey1", @missing_event.reload.atproto_uri
  end

  # Connecting an account

  test 'an organisation admin connects an account, stored with the DID and handle Bluesky gives, and disconnects it' do
    create_organisation
    sign_in_with_rack(@account)
    with_atproto do
      post "/o/#{@organisation.slug}/atproto/connect", atproto_handle: ' @organisation.test ', atproto_app_password: 'organisation-password'
    end

    assert_equal "/o/#{@organisation.slug}/atproto/connect", URI(last_response.location).path
    @organisation.reload
    assert_equal ['organisation.test', 'organisation-password', ORGANISATION_DID], [@organisation.atproto_handle, @organisation.atproto_app_password, @organisation.atproto_did]

    post "/o/#{@organisation.slug}/atproto/disconnect"
    assert last_response.redirect?
    @organisation.reload
    assert_equal [nil, nil, nil], [@organisation.atproto_handle, @organisation.atproto_app_password, @organisation.atproto_did]
  end

  test "credentials Bluesky refuses aren't saved" do
    create_organisation
    sign_in_with_rack(@account)
    with_atproto do
      post "/o/#{@organisation.slug}/atproto/connect", atproto_handle: 'organisation.test', atproto_app_password: 'wrong-password'
    end

    assert last_response.ok?
    assert_includes last_response.body, 'Invalid Bluesky/ATProto credentials'
    refute @organisation.reload.atproto_connected?
    assert_nil @organisation.atproto_did
  end

  test "someone who isn't an admin of the organisation can't see, connect or disconnect its account" do
    connected_organisation
    [nil, FactoryBot.create(:account)].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      @organisation.organisationships.create!(account: account) if account

      get "/o/#{@organisation.slug}/atproto/connect"
      assert last_response.redirect?
      with_atproto do
        post "/o/#{@organisation.slug}/atproto/connect", atproto_handle: 'other.test', atproto_app_password: 'other-password'
      end
      assert last_response.redirect?
      post "/o/#{@organisation.slug}/atproto/disconnect"
      assert last_response.redirect?

      @organisation.reload
      assert_equal ['organisation.test', 'organisation-password', ORGANISATION_DID], [@organisation.atproto_handle, @organisation.atproto_app_password, @organisation.atproto_did]
    end
    assert_equal [], other_client.calls
  end
end
