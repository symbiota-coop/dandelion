require_relative '../test_config'

# The Dandelion Daily (/daily and a location's /daily/:name): the AI-written edition late:errands makes each day from
# public events (Daily.publish), and the pages that show it
class EventsDailyTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  setup do
    # The book and film of the day come from GitHub CSVs (Library), which tests don't fetch
    LIBRARY_CACHE[:books] = [{ slug: 'the-dawn-of-everything', title: 'The Dawn of Everything' }]
    LIBRARY_CACHE[:films] = [{ slug: 'koyaanisqatsi', name: 'Koyaanisqatsi', url: 'https://example.com/koyaanisqatsi' }]
  end

  teardown do
    LIBRARY_CACHE.delete(:books)
    LIBRARY_CACHE.delete(:films)
  end

  # Daily.publish with the model answering each story by linking every event it was given (as the instructions ask),
  # or with answer if given. Returns the prompts, keyed by the article's title
  def publish(date = Date.today, location: nil, answer: :links)
    prompts = {}
    chat = lambda do |prompt, **|
      title = Daily::ARTICLES.detect { |article| prompt.start_with?(article[:prompt]) }[:title]
      prompts[title] = prompt
      next answer unless answer == :links

      prompt.scan(/^# (.+?), .*\nURL: (\S+)/).map { |name, url| "[#{name}](#{url})" }.join(' and ')
    end
    OpenRouter.stub(:chat, chat) { Daily.publish(date, location: location) }
    prompts
  end

  # A listed event (one with tickets is browsable) with a description, starting at start. has_image is set from its
  # image as it saves, so it's set afterwards
  def public_event(name, start, as: :event, has_image: false, **attrs)
    event = create_event(name: name, start_time: start, end_time: start + 2.hours, description: "About #{name}", prices: [10], as: as, **attrs)
    event.set(has_image: true) if has_image
    event
  end

  def noon(date)
    Time.zone.local(date.year, date.month, date.day, 12)
  end

  def stash_edition(date, location: nil, articles: [{ 'title' => "Today's events", 'summary' => 'Quiet all day.' }], facilitator_id: nil)
    Stash.create!(key: Daily.key(date, location: location), value: { 'articles' => articles, 'facilitator_id' => facilitator_id }.to_json)
  end

  def create_location(name: 'Stockholm', **attrs)
    Location.create!(name: name, query: name, signal_group_link: 'https://signal.group/#daily', **attrs)
  end

  # A facilitator who qualifies for facilitator of the day: a photo, 20 feedbacks and an event facilitated this year
  def create_qualifying_facilitator(event, **attrs)
    account = FactoryBot.create(:account, **attrs)
    account.set(has_image: true, event_feedbacks_as_facilitator_count: 20)
    event.event_facilitations.create!(account: account)
    account
  end

  # Which events each story is told from

  test "today's story is told from the day's public events, never secret, locked or deleted ones" do
    today = Date.today
    public_event('Sound Bath', noon(today))
    public_event('Secret Supper', noon(today), as: :secret, secret: true)
    public_event('Locked Circle', noon(today), as: :locked, locked: true)
    public_event('Deleted Dance', noon(today), as: :deleted).destroy
    public_event('Tomorrow Talk', noon(today + 1), as: :tomorrow)
    public_event('Yesterday Yoga', noon(today - 1), as: :yesterday)
    public_event('Embeds Only Walk', noon(today), as: :embeds_only, minimal_only: true)

    prompt = publish(today)["Today's events"]

    assert_includes prompt, "URL: #{ENV['BASE_URI']}/e/#{@event.slug}"
    assert_includes prompt, 'About Sound Bath'
    ['Secret Supper', 'Locked Circle', 'Deleted Dance', 'Tomorrow Talk', 'Yesterday Yoga', 'Embeds Only Walk'].each do |name|
      refute_includes prompt, name
    end
  end

  test "today is the day in the site's time zone, not UTC" do
    today = Date.today
    midnight = Time.zone.local(today.year, today.month, today.day)
    public_event('Just After Midnight', midnight + 30.minutes) # the evening before, in UTC
    public_event('Just Before Midnight', midnight - 30.minutes, as: :before)

    prompt = publish(today)["Today's events"]

    assert_includes prompt, 'Just After Midnight'
    refute_includes prompt, 'Just Before Midnight'
  end

  test "an event without a description isn't in today's or the recently listed story" do
    today = Date.today
    public_event('Described', noon(today))
    public_event('Undescribed', noon(today), as: :undescribed, description: nil)
    Event.unscoped.update_all(created_at: noon(today - 1))

    prompts = publish(today)

    ["Today's events", 'Recently listed'].each do |title|
      assert_includes prompts[title], 'Described'
      refute_includes prompts[title], 'Undescribed'
    end
  end

  test 'the recently listed story is from the public events listed the day before' do
    today = Date.today
    public_event('Listed Yesterday', noon(today + 10))
    public_event('Listed Today', noon(today + 11), as: :listed_today)
    public_event('Listed Earlier', noon(today + 12), as: :listed_earlier)
    public_event('Secret Listed Yesterday', noon(today + 13), as: :secret, secret: true)
    [@event, @secret].each { |event| event.set(created_at: noon(today - 1)) }
    @listed_earlier.set(created_at: noon(today - 3))

    prompt = publish(today)['Recently listed']

    assert_includes prompt, 'Listed Yesterday'
    ['Listed Today', 'Listed Earlier', 'Secret Listed Yesterday'].each { |name| refute_includes prompt, name }
  end

  test 'the feedback report is from the answers given on public events that ended two days before' do
    today = Date.today
    attendee = FactoryBot.create(:account)
    public_event('Ended Two Days Ago', noon(today - 2) - 2.hours)
    public_event('Ended Yesterday', noon(today - 1) - 2.hours, as: :yesterday)
    public_event('Blank Feedback', noon(today - 2) - 2.hours, as: :blank)
    public_event('Secret Feedback', noon(today - 2) - 2.hours, as: :secret, secret: true)
    [@event, @yesterday, @secret].each do |event|
      event.event_feedbacks.create!(account: attendee, answers: [['What did you value?', "The calm at #{event.name}"]])
    end
    @blank.event_feedbacks.create!(account: attendee, answers: [['What did you value?', '']])

    prompt = publish(today)['Feedback report']

    assert_includes prompt, 'The calm at Ended Two Days Ago'
    refute_includes prompt, 'About Ended Two Days Ago', 'gave the event description rather than its feedback'
    ['Ended Yesterday', 'Blank Feedback', 'Secret Feedback'].each { |name| refute_includes prompt, name }
  end

  test 'the trending story is from upcoming public events with an image, trending ones first' do
    today = Date.today
    public_event('Soonest', noon(today + 1), has_image: true)
    public_event('Trending Later', noon(today + 20), as: :trending, has_image: true, trending: true)
    public_event('No Image', noon(today + 1), as: :no_image)
    public_event('Secret Trend', noon(today + 1), as: :secret, has_image: true, trending: true, secret: true)
    public_event('Already Over', noon(today - 3), as: :over, has_image: true, trending: true)

    prompt = publish(today)['Trending events']

    assert_operator prompt.index('Trending Later'), :<, prompt.index('Soonest')
    ['No Image', 'Secret Trend', 'Already Over'].each { |name| refute_includes prompt, name }
  end

  # Publishing

  test "the edition is kept once a day: running late:errands again doesn't write it again" do
    today = Date.today
    public_event('Sound Bath', noon(today))

    assert_equal ["Today's events"], publish(today).keys
    edition = Daily.edition(today)
    assert_equal [{ 'title' => "Today's events", 'summary' => "[Sound Bath](#{ENV['BASE_URI']}/e/#{@event.slug})" }], edition['articles'].first(1)

    assert_empty publish(today, answer: 'Rewritten'), 'asked the model again'
    assert_equal 1, Stash.and(key: Daily.key(today)).count
    assert_equal edition, Daily.edition(today)
  end

  test 'a day with no events still gets a main edition, with no stories' do
    publish(Date.today)

    assert_equal [], Daily.edition(Date.today)['articles']
  end

  test "an edition the model didn't write a story for isn't kept, so the next run tries again" do
    today = Date.today
    public_event('Sound Bath', noon(today))

    reported = []
    ErrorReporting.stub(:capture_exception, ->(error, **) { reported << error }) { publish(today, answer: nil) }

    assert_nil Daily.edition(today)
    assert_equal 1, reported.length
    assert_match(/no summary for Today's events\z/, reported.first.message)

    publish(today)
    assert Daily.edition(today)
  end

  # Location editions

  test "a location's edition is from the public events in its area, and only on a day with news" do
    today = Date.today
    location = create_location
    Geocoder::Lookup::Test.add_stub('Berlin, Germany', [{ 'coordinates' => [52.52, 13.405] }])
    public_event('Stockholm Sauna', noon(today))
    public_event('Berlin Rave', noon(today), as: :berlin, location: 'Berlin, Germany')
    public_event('Secret Stockholm Sauna', noon(today), as: :secret, secret: true)

    prompts = publish(today, location: location)

    assert_includes prompts["Today's events"], 'Stockholm Sauna'
    assert_includes prompts["Today's events"], 'in and around Stockholm'
    refute_includes prompts["Today's events"], 'Berlin Rave'
    refute_includes prompts["Today's events"], 'Secret Stockholm Sauna'
    assert Daily.edition(today, location: location)
    assert_nil Daily.edition(today), "made the main edition from a location's run"

    quiet = create_location(name: 'Malmö')
    @event.destroy
    @secret.destroy
    Geocoder::Lookup::Test.add_stub('Malmö', [{ 'coordinates' => [55.605, 13.0038] }])
    assert_empty publish(today, location: quiet)
    assert_nil Daily.edition(today, location: quiet)
  ensure
    Geocoder::Lookup::Test.delete_stub('Berlin, Germany')
    Geocoder::Lookup::Test.delete_stub('Malmö')
  end

  test 'the online edition is from online events, and a location without a Signal group gets none' do
    today = Date.today
    online = create_location(name: 'Online')
    public_event('Zoom Circle', noon(today), location: 'Online')
    public_event('Stockholm Sauna', noon(today), as: :in_person)

    prompt = publish(today, location: online)["Today's events"]
    assert_includes prompt, 'Zoom Circle'
    assert_includes prompt, 'These events are online.'
    refute_includes prompt, 'Stockholm Sauna'

    unlisted = create_location(name: 'Göteborg', signal_group_link: nil)
    assert_empty publish(today, location: unlisted)
    assert_nil Daily.edition(today, location: unlisted)
    assert_equal [online], Daily.locations.to_a
  end

  # Facilitator of the day

  test 'facilitator of the day has a photo, 20 feedbacks and facilitated in the last year, and for a location, there' do
    public_event('Sound Bath', noon(Date.today + 1))
    facilitator = create_qualifying_facilitator(@event)
    create_qualifying_facilitator(@event, name: 'No Photo').set(has_image: false)
    create_qualifying_facilitator(@event, name: 'Few Feedbacks').set(event_feedbacks_as_facilitator_count: 19)
    create_qualifying_facilitator(@event, name: 'Long Ago').event_facilitations.first.set(created_at: 13.months.ago)

    assert_equal facilitator.id.to_s, Daily.facilitator_id

    online = create_location(name: 'Online')
    assert_nil Daily.facilitator_id(online)
  end

  test "someone who hid their profile is never facilitator of the day, nor shown as one once they've hidden it" do
    covers_route 'GET /daily'
    public_event('Sound Bath', noon(Date.today + 1))
    facilitator = create_qualifying_facilitator(@event, name: 'Fay Cilitator')
    create_qualifying_facilitator(@event, name: 'Hidden Facilitator', hidden: true)

    10.times { assert_equal facilitator.id.to_s, Daily.facilitator_id }

    stash_edition(Date.today, facilitator_id: facilitator.id.to_s)
    facilitator.set(hidden: true)
    get '/daily'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Facilitator of the day'
    refute_includes last_response.body, 'Fay Cilitator'
    refute_includes last_response.body, "/u/#{facilitator.username}"
  end

  # The page

  test 'the page shows the latest edition by default, its stories linking their events, with arrows between editions' do
    covers_route 'GET /books/:slug'
    covers_route 'GET /films/:slug'
    today = Date.today
    public_event('Sound Bath', noon(today))
    public_event('Secret Supper', noon(today), as: :secret, secret: true)
    facilitator = create_qualifying_facilitator(@event, name: 'Fay Cilitator')
    publish(today)
    stash_edition(today - 3, articles: [{ 'title' => "Today's events", 'summary' => 'Older news.' }])

    visit '/daily'

    assert page.has_link?('Sound Bath', href: "#{ENV['BASE_URI']}/e/#{@event.slug}")
    assert page.has_no_content?('Secret Supper')
    assert page.has_content?(today.strftime('%A, %B %-d, %Y'))
    assert page.has_content?("No. #{Daily.number(today)}")
    assert page.has_link?('Fay Cilitator', href: "/u/#{facilitator.username}")
    assert page.has_css?('a[href="/books/the-dawn-of-everything"]')
    assert page.has_css?('a[href="https://example.com/koyaanisqatsi"]')
    assert page.has_css?('.nav-arrow.disabled .bi-arrow-right')

    find('a[title="Previous edition"]').click
    assert page.has_content?('Older news.')
    assert page.has_content?((today - 3).strftime('%A, %B %-d, %Y'))
    find('a[title="Next edition"]').click
    assert page.has_link?('Sound Bath')
  end

  test "today's page says it's still at the printers until it's out" do
    stash_edition(Date.today - 1)

    visit "/daily?date=#{Date.today.strftime('%Y-%m-%d')}"

    assert page.has_content?('Still at the printers')
    click_on 'Read the latest Daily'
    assert page.has_content?('Quiet all day.')
  end

  test "a location's page shows its edition, the other editions out that day and the main Daily's" do
    today = Date.today
    stockholm = create_location
    malmo = create_location(name: 'Malmo')
    stash_edition(today, location: stockholm, articles: [{ 'title' => "Today's events", 'summary' => 'Saunas all round.' }])
    stash_edition(today, location: malmo)
    stash_edition(today, articles: [{ 'title' => "Today's events", 'summary' => 'Everywhere at once.' }])

    visit '/daily/Stockholm'

    assert page.has_content?('Saunas all round.')
    assert page.has_css?('.newspaper-edition-current', text: 'Stockholm')
    assert page.has_no_content?('Everywhere at once.')
    assert page.has_no_content?('Facilitator of the day')
    click_on 'Malmo'
    assert page.has_content?('Quiet all day.')
    click_on 'The Dandelion Daily'
    assert page.has_content?('Everywhere at once.')
  end

  test "a past date with no edition is a 404, a future one isn't indexed, and an unknown location's page is a 404" do
    covers_route 'GET /daily/:name'
    stash_edition(Date.today - 1)

    get "/daily?date=#{(Date.today - 2).strftime('%Y-%m-%d')}"
    assert_equal 404, last_response.status
    assert_includes last_response.body, 'Not available'

    get "/daily?date=#{(Date.today + 1).strftime('%Y-%m-%d')}"
    assert_equal 200, last_response.status
    assert_equal 'noindex', last_response.headers['X-Robots-Tag']

    get '/daily', date: 'not-a-date'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Quiet all day.'

    get '/daily', date: ['2025-01-31']
    assert_equal 200, last_response.status

    get '/daily/Atlantis'
    assert_equal 404, last_response.status
  end
end
