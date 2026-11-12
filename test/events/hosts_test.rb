require_relative '../test_config'

# An event's co-hosts and carousels, and the caches that hold them
class EventHostsTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def tag_event(event, tag)
    event.event_tagships.create!(event_tag: tag)
    event.reload
  end

  def tag_carousel(carousel, tag)
    carousel.carouselships.create!(event_tag: tag)
    carousel.sync_tagged_event_carousel_ids_without_delay(tag.id)
    carousel
  end

  def listing_event_ids
    JSON.parse(last_response.body).map { |event| event['id'] }
  end

  test 'tagging a carousel stores matching event carousel ids' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_event(@event, tag)
    assert_empty Array(@event.carousel_ids)

    tag_carousel(carousel, tag)
    @event.reload
    assert_equal [carousel.id], @event.carousel_ids
  end

  test 'tagging an event does not store another organisation carousel with the same tag' do
    create_event
    other_organisation = FactoryBot.create(:organisation)
    tag = FactoryBot.create(:event_tag)
    other_carousel = FactoryBot.create(:carousel, organisation: other_organisation)
    tag_carousel(other_carousel, tag)
    tag_event(@event, tag)

    assert_empty Array(@event.carousel_ids)
  end

  test 'adding and removing a cohost updates the cohost organisation carousel ids' do
    create_event
    cohost = FactoryBot.create(:organisation)
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: cohost)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    assert_empty Array(@event.carousel_ids)

    @event.cohostships.create!(organisation: cohost)
    @event.reload
    assert_equal [carousel.id], @event.carousel_ids

    @event.cohostships.find_by(organisation: cohost).destroy
    @event.reload
    assert_empty Array(@event.carousel_ids)
  end

  test 'hosts_ids_cache holds the organisation and its cohosts' do
    create_event
    assert_equal [@organisation.id], @event.hosts_ids_cache

    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    assert_equal [@organisation.id, cohost.id], @event.reload.hosts_ids_cache

    @event.cohostships.find_by(organisation: cohost).destroy
    assert_equal [@organisation.id], @event.reload.hosts_ids_cache
  end

  test "co-hosts added and removed through different copies of an event, as by two admins at once, don't undo each other" do
    create_event
    first = FactoryBot.create(:organisation)
    second = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: first)
    stale = Event.find(@event.id)

    @event.cohostships.create!(organisation: second)
    stale.cohostships.find_by(organisation: first).destroy

    @event.reload
    assert_equal [second.id], @event.cohosts_ids_cache
    assert_equal [@organisation.id, second.id], @event.hosts_ids_cache
  end

  test "an event's carousels come from all its co-hosts, including one added through another copy of it" do
    create_event
    tag = FactoryBot.create(:event_tag)
    tag_event(@event, tag)
    first = FactoryBot.create(:organisation)
    second = FactoryBot.create(:organisation)
    carousel = FactoryBot.create(:carousel, organisation: first)
    tag_carousel(carousel, tag)
    stale = Event.find(@event.id)

    @event.cohostships.create!(organisation: first)
    stale.cohostships.create!(organisation: second)

    assert_equal [carousel.id], @event.reload.carousel_ids
  end

  test "removing an old co-hostship of the host's own organisation keeps it among the event's hosts" do
    create_event
    # New ones are refused, but some were saved before that check
    Cohostship.collection.insert_one(event_id: @event.id, organisation_id: @organisation.id)
    @event.set(cohosts_ids_cache: [@organisation.id])

    Cohostship.find_by(event_id: @event.id).destroy

    @event.reload
    assert_empty @event.cohosts_ids_cache
    assert_equal [@organisation.id], @event.hosts_ids_cache
  end

  test 'events_including_cohosted returns hosted and cohosted events but not deleted ones' do
    create_event
    create_event(as: :deleted_event)
    @deleted_event.destroy
    cohosted_event = FactoryBot.create(:event)
    cohosted_event.cohostships.create!(organisation: @organisation)
    FactoryBot.create(:event)

    assert_equal [@event.id, cohosted_event.id].sort, @organisation.events_including_cohosted.pluck(:id).sort
  end

  test 'hinted hints the hosts index only where it exists' do
    create_event
    Event.reset_existing_index_names!
    assert_nil @organisation.events_including_cohosted.hinted(Event::HOSTS_INDEX).options[:hint]

    Event.collection.indexes.create_one({ hosts_ids_cache: 1, deleted_at: 1, secret: 1, start_time: 1 }, name: Event::HOSTS_INDEX)
    Event.reset_existing_index_names!
    assert_nil @organisation.events_including_cohosted.options[:hint]
    events = @organisation.events_including_cohosted.hinted(Event::HOSTS_INDEX).publicly_visible.future_current_evergreen
    assert_equal Event::HOSTS_INDEX, events.options[:hint]
    assert_equal [@event.id], events.pluck(:id)
    assert_equal 1, events.count
  ensure
    Event.collection.indexes.drop_one(Event::HOSTS_INDEX) if Event.collection.indexes.any? { |index| index['name'] == Event::HOSTS_INDEX }
    Event.reset_existing_index_names!
  end

  test 'hosts cache sync finds and repairs a stale hosts_ids_cache' do
    create_event
    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    @event.unset(:hosts_ids_cache)

    out_of_sync = Event.check_hosts_cache_sync
    assert_equal([@event.id], out_of_sync.map { |entry| entry[:event].id })
    assert_nil @event.reload.hosts_ids_cache

    Event.check_hosts_cache_sync(fix: true)
    assert_equal [@organisation.id, cohost.id], @event.reload.hosts_ids_cache
    assert_empty Event.check_hosts_cache_sync
  end

  test 'cohosts cache sync finds and repairs a missing or extra co-host, and reports nothing once in sync' do
    create_event
    create_event(as: :other_event)
    cohost = FactoryBot.create(:organisation)
    gone = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    @other_event.cohostships.create!(organisation: cohost)
    assert_empty Event.check_cohosts_cache_sync

    @event.set(cohosts_ids_cache: [])
    @other_event.add_to_set(cohosts_ids_cache: gone.id)

    out_of_sync = Event.check_cohosts_cache_sync
    assert_equal [@event.id, @other_event.id].sort, out_of_sync.map { |entry| entry[:event].id }.sort
    entry = out_of_sync.find { |e| e[:event].id == @event.id }
    assert_equal({ current: [], expected: [cohost.id.to_s] }, entry.slice(:current, :expected))

    Event.check_cohosts_cache_sync(fix: true)
    assert_equal [cohost.id], @event.reload.cohosts_ids_cache
    assert_equal [@organisation.id, cohost.id], @event.hosts_ids_cache
    assert_equal [cohost.id], @other_event.reload.cohosts_ids_cache
    assert_empty Event.check_cohosts_cache_sync
  end

  test 'removing a tag or carouselship clears carousel ids' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    assert_equal [carousel.id], @event.carousel_ids

    @event.event_tagships.find_by(event_tag: tag).destroy
    @event.reload
    assert_empty Array(@event.carousel_ids)

    tag_event(@event, tag)
    assert_equal [carousel.id], @event.carousel_ids

    carousel.carouselships.find_by(event_tag: tag).destroy
    carousel.sync_tagged_event_carousel_ids_without_delay(tag.id)
    @event.reload
    assert_empty Array(@event.carousel_ids)
  end

  test 'destroying a carousel clears its id from events' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    carousel.destroy
    @event.reload

    assert_empty Array(@event.carousel_ids)
  end

  test 'organisation events json listing filters by stored carousel ids' do
    create_event(as: :matching)
    create_event(as: :other)
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@matching, tag)

    header 'Referer', "http://example.org/o/#{@organisation.slug}/events"
    get "/o/#{@organisation.slug}/events.json", carousel_ids: [carousel.id.to_s]
    assert last_response.ok?
    assert_includes listing_event_ids, @matching.id.to_s
    refute_includes listing_event_ids, @other.id.to_s
  end

  test 'organisation events json listing ignores another organisation carousel id' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    other_carousel = FactoryBot.create(:carousel, organisation: FactoryBot.create(:organisation))

    header 'Referer', "http://example.org/o/#{@organisation.slug}/events"
    get "/o/#{@organisation.slug}/events.json", carousel_ids: [other_carousel.id.to_s]
    assert last_response.ok?
    refute_includes listing_event_ids, @event.id.to_s
  end
end
