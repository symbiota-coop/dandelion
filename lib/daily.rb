# The Dandelion Daily (/daily): each date's AI-written articles and facilitator of the day, worked out once and kept
# in a Stash. late:errands makes today's; other dates are made the first time someone opens them
module Daily
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

  # { 'articles' => [{ 'title' =>, 'summary' => markdown }], 'facilitator_id' => }
  def self.edition(date)
    key = "daily/#{date.to_fs(:db_local)}"
    if (stash = Stash.find_by(key: key))
      return JSON.parse(stash.value)
    end

    edition = generate(date)
    # Don't keep an edition missing a summary the model failed to write, so the next visit tries again
    return edition if edition['articles'].any? { |article| article['summary'].nil? }

    begin
      Stash.create(key: key, value: edition.to_json)
    rescue Mongo::Error::OperationFailure # another process stashed it first
      return JSON.parse(Stash.find_by(key: key).value)
    end
    edition
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
