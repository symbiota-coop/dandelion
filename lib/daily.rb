# The Dandelion Daily (/daily): each date's AI-written articles and facilitator of the day, worked out once and kept
# in a Stash. Each Location with a Signal group has its own edition too (/locations/:name/daily), from the events in
# its area. Only late:errands makes them, with Daily.publish(Date.today) and Daily.publish(Date.today, location:);
# the pages just show what's been kept
module Daily
  class GenerationFailed < StandardError; end

  # How every story is written, in place of EventsSummary's general instructions: a short news story about a few of
  # the events, rather than a summary that links them all
  STYLE = <<~TEXT.freeze
    Write it as a short newspaper story: 100 to 150 words of prose in one or two paragraphs, with no headline.
    Pick the three to five events most worth a reader's attention rather than mentioning them all, and say something concrete about each: where it is, what happens there, who it's for.
    Say only what the events' own descriptions say: don't add details, settings or atmosphere they don't give.
    Write plainly and warmly, in British English, like a good local reporter. Avoid marketing language and clichés such as "diverse", "vibrant", "enthusiasts", "immersive", "journey" and "something for everyone". No bullet points, italics or headers.
    Do not mention specific dates or times.
    Link each event's name the first time it appears, using markdown like [Event Name](URL), and link nothing else.
  TEXT

  # Each article's events lambda takes the date and the events it may pick from: every public event, or a location's
  ARTICLES = [
    {
      title: "Today's events",
      prompt: "The day's lead story: what's on today, from these events.",
      events: lambda { |date, events|
        events.and(:description.ne => nil)
              .and(:start_time.gte => date, :start_time.lt => date + 1)
      }
    },
    {
      title: 'Feedback report',
      prompt: "What people said about these recent events, from their attendees' feedback: what they valued, and anything they'd change. Put it in your own words, without quoting or naming attendees.",
      use_feedback: true,
      events: lambda { |date, events|
        events.and(:end_time.gte => date - 2, :end_time.lt => date - 1)
              .reject { |event| event.event_feedbacks.empty? || event.event_feedbacks.all? { |ef| !ef.answers || ef.answers.map { |_q, a| a.blank? }.all? } }
      }
    },
    {
      title: 'Recently listed',
      prompt: 'Events newly listed on Dandelion, from these.',
      events: lambda { |date, events|
        events.and(:description.ne => nil)
              .and(:created_at.gte => date - 1, :created_at.lt => date)
      }
    },
    {
      title: 'Trending events',
      prompt: 'The upcoming events drawing the most interest right now, from these.',
      events: ->(date, events) { events.trending(date, limit: 3) }
    }
  ].freeze

  # The locations with their own edition: those with a Signal group, biggest first
  def self.locations
    Location.and(:signal_group_link.ne => nil).order('events_count desc')
  end

  # Of those, the ones with an edition on the date
  def self.locations_with_edition(date)
    locations.select { |location| Stash.and(key: key(date, location: location)).exists? }
  end

  # A location's keys sit under daily/locations/, which sorts after every daily/<date> as dates start with a digit,
  # so the main Daily's ranges below don't reach them
  def self.prefix(location = nil)
    location ? "daily/locations/#{location.id}/" : 'daily/'
  end

  def self.key(date, location: nil)
    "#{prefix(location)}#{date.to_fs(:db_local)}"
  end

  # { 'articles' => [{ 'title' =>, 'summary' => markdown }], 'facilitator_id' => }, or nil if it hasn't been made
  def self.edition(date, location: nil)
    stash = Stash.find_by(key: key(date, location: location))
    JSON.parse(stash.value) if stash
  end

  # The day the Daily first came out, its No. 1
  FIRST_DATE = Date.new(2025, 1, 31)

  # The edition's number in the masthead, counting a day at a time from FIRST_DATE (not the stashed editions, as
  # those under the old /daily?date= keys no longer count), or nil before it
  def self.number(date)
    (date - FIRST_DATE).to_i + 1 if date >= FIRST_DATE
  end

  # The latest date with an edition, up to today
  def self.latest_date(location: nil)
    date_of(Stash.and(:key.gt => prefix(location), :key.lte => key(Date.today, location: location)).order(key: -1), location)
  end

  # The nearest dates either side of date with an edition, for the arrows. Forward goes to today if no later
  # edition is out, so today stays reachable before late:errands has made it
  def self.previous_date(date, location: nil)
    date_of(Stash.and(:key.gt => prefix(location), :key.lt => key(date, location: location)).order(key: -1), location)
  end

  def self.next_date(date, location: nil)
    return if date >= Date.today

    date_of(Stash.and(:key.gt => key(date, location: location), :key.lte => key(Date.today, location: location)).order(key: 1), location) || Date.today
  end

  def self.date_of(stashes, location)
    stash = stashes.only(:key).first
    Date.parse(stash.key.delete_prefix(prefix(location))) if stash
  end

  # The events an edition picks from: every public event, or those in a location's area (nil if its place can't be
  # found, so it gets no edition rather than everyone's)
  def self.events(location)
    location ? location.area_events : Event.live.publicly_visible.browsable
  end

  # Makes and keeps the date's edition, unless it already has one. A location only gets one on a day with news
  def self.publish(date, location: nil)
    return if Stash.and(key: key(date, location: location)).exists?
    return if location && !location.signal_group_link
    return unless events(location)

    edition = generate(date, location: location)
    return if location && edition['articles'].empty?

    # Don't keep an edition missing a summary the model failed to write. Errors raised in late:errands reach Sentry
    # anyway, but OpenRouter.chat returns nil when the model doesn't answer, so say so
    if (failed = edition['articles'].select { |article| article['summary'].nil? }).any?
      titles = failed.map { |article| article['title'] }.join(', ')
      ErrorReporting.capture_exception(GenerationFailed.new("No Daily#{" for #{location.name}" if location} for #{date}: no summary for #{titles}"))
      return
    end

    begin
      Stash.create(key: key(date, location: location), value: edition.to_json)
    rescue Mongo::Error::OperationFailure # another process stashed it first
      nil
    end
  end

  def self.generate(date, location: nil)
    place = (location.online? ? ' These events are online.' : " These events are in and around #{location.query}.") if location
    {
      'articles' => ARTICLES.filter_map do |article|
        events = article[:events].call(date, events(location))
        next if events.empty?

        summary = EventsSummary.generate("#{article[:prompt]}#{place}", events, use_feedback: article[:use_feedback], general_instructions: STYLE)
        { 'title' => article[:title], 'summary' => summary }
      end,
      'facilitator_id' => facilitator_id(location)
    }
  end

  # A facilitator with a photo and plenty of feedback who's facilitated in the last year: for a location, at one of
  # its events, or none
  def self.facilitator_id(location = nil)
    account = if Padrino.env == :development
                Account.first
              else
                facilitations = EventFacilitation.and(:created_at.gt => 1.year.ago)
                facilitations = facilitations.and(:event_id.in => location.area_events.and(:start_time.gt => 1.year.ago).pluck(:id)) if location
                Account.and(
                  :has_image => true,
                  :event_feedbacks_as_facilitator_count.gte => 20,
                  :id.in => facilitations.pluck(:account_id).map(&:to_s).uniq
                ).sample
              end
    account&.id&.to_s
  end
end
