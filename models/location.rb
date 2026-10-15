class Location
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :name, type: String
  field :query, type: String
  field :events_count, type: Integer
  field :signal_group_link, type: String
  field :summary, type: String

  validates_uniqueness_of :name
  validates_http_url :signal_group_link

  def self.protected_attributes
    %w[summary]
  end

  def online?
    name == 'Online'
  end

  # Upcoming public events here, as the location's page lists them
  def events
    events = Event.live.publicly_visible.browsable.future
    if online?
      events.online
    elsif (bounding_box = GeocodeBounds.for(query))
      events.and(coordinates: { '$geoWithin' => { '$box' => bounding_box } })
    else
      events
    end
  end

  # The AI summary of the vibe of its events (markdown), made daily by late:errands. Keeps the last one if the model doesn't answer
  def generate_summary
    events = self.events.to_a
    return if events.empty?

    summary = EventsSummary.generate(
      "Create a summary of these events, happening in #{online? ? 'online' : query}, in one paragraph of three sentences.
      Don't mention specific events, just give a general sense of the vibe.",
      events.sample(20),
      general_instructions: 'Return well-formatted markdown. Do not use italics. Do not use headers.'
    )
    set(summary: summary) if summary
  end
end
