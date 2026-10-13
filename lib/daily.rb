# The Dandelion Daily (/daily): each date's AI-written articles and facilitator of the day, worked out once and kept
# in a Stash. Only late:errands makes them, with Daily.publish(Date.today); /daily just shows what's been kept
module Daily
  class GenerationFailed < StandardError; end

  ARTICLES = [
    {
      title: "Today's events",
      prompt: 'Create a two-paragraph summary of these events, happening today. IMPORTANT: Two paragraphs only.',
      events: lambda { |date|
        Event.live.publicly_visible.browsable
             .and(:description.ne => nil)
             .and(:start_time.gte => date, :start_time.lt => date + 1)
      }
    },
    {
      title: 'Feedback report',
      prompt: 'Create a two-paragraph summary of the feedback on these events. IMPORTANT: Two paragraphs only.',
      use_feedback: true,
      events: lambda { |date|
        Event.live.publicly_visible.browsable
             .and(:end_time.gte => date - 2, :end_time.lt => date - 1)
             .reject { |event| event.event_feedbacks.empty? || event.event_feedbacks.all? { |ef| !ef.answers || ef.answers.map { |_q, a| a.blank? }.all? } }
      }
    },
    {
      title: 'Recently listed',
      prompt: 'Create a two-paragraph summary of these newly-listed event(s). IMPORTANT: Two paragraphs only.',
      events: lambda { |date|
        Event.live.publicly_visible.browsable
             .and(:description.ne => nil)
             .and(:created_at.gte => date - 1, :created_at.lt => date)
      }
    },
    {
      title: 'Trending events',
      prompt: 'Create a two-paragraph summary of these trending, upcoming event(s). IMPORTANT: Two paragraphs only.',
      events: ->(date) { Event.trending(date, limit: 3) }
    }
  ].freeze

  def self.key(date)
    "daily/#{date.to_fs(:db_local)}"
  end

  # { 'articles' => [{ 'title' =>, 'summary' => markdown }], 'facilitator_id' => }, or nil if it hasn't been made
  def self.edition(date)
    stash = Stash.find_by(key: key(date))
    JSON.parse(stash.value) if stash
  end

  # The latest date with an edition, up to today
  def self.latest_date
    date_of(Stash.and(:key.gt => 'daily/', :key.lte => key(Date.today)).order(key: -1))
  end

  # The nearest dates either side of date with an edition, for the arrows. Forward goes to today if no later
  # edition is out, so today stays reachable before late:errands has made it
  def self.previous_date(date)
    date_of(Stash.and(:key.gt => 'daily/', :key.lt => key(date)).order(key: -1))
  end

  def self.next_date(date)
    return if date >= Date.today

    date_of(Stash.and(:key.gt => key(date), :key.lte => key(Date.today)).order(key: 1)) || Date.today
  end

  def self.date_of(stashes)
    stash = stashes.only(:key).first
    Date.parse(stash.key.delete_prefix('daily/')) if stash
  end

  # Makes and keeps the date's edition, unless it already has one
  def self.publish(date)
    return if Stash.and(key: key(date)).exists?

    edition = generate(date)
    # Don't keep an edition missing a summary the model failed to write. Errors raised in late:errands reach Sentry
    # anyway, but OpenRouter.chat returns nil when the model doesn't answer, so say so
    if (failed = edition['articles'].select { |article| article['summary'].nil? }).any?
      titles = failed.map { |article| article['title'] }.join(', ')
      ErrorReporting.capture_exception(GenerationFailed.new("No Daily for #{date}: no summary for #{titles}"))
      return
    end

    begin
      Stash.create(key: key(date), value: edition.to_json)
    rescue Mongo::Error::OperationFailure # another process stashed it first
      nil
    end
  end

  def self.generate(date)
    {
      'articles' => ARTICLES.filter_map do |article|
        events = article[:events].call(date)
        next if events.empty?

        { 'title' => article[:title], 'summary' => EventsSummary.generate(article[:prompt], events, use_feedback: article[:use_feedback]) }
      end,
      'facilitator_id' => facilitator_id
    }
  end

  def self.facilitator_id
    account = if Padrino.env == :development
                Account.first
              else
                Account.and(
                  :has_image => true,
                  :event_feedbacks_as_facilitator_count.gte => 20,
                  :id.in => EventFacilitation.and(:created_at.gt => 1.year.ago).pluck(:account_id).map(&:to_s).uniq
                ).sample
              end
    account&.id&.to_s
  end
end
