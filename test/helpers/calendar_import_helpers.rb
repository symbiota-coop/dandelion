# Serves iCal feeds and Luma pages to organisation calendar imports without the network
module CalendarImportHelpers
  FEED_URL = 'https://calendar.google.com/calendar/ical/community/basic.ics'.freeze
  OTHER_FEED_URL = 'https://outlook.office365.com/owa/calendar/other/calendar.ics'.freeze
  LUMA_FEED_URL = 'https://api.luma.com/ics/get?entity=calendar&id=cal-test'.freeze

  def ical(*vevents, name: 'Community Calendar')
    <<~ICAL
      BEGIN:VCALENDAR
      VERSION:2.0
      X-WR-CALNAME:#{name}
      #{vevents.join("\n")}
      END:VCALENDAR
    ICAL
  end

  # Each keyword is a property (dtstart: ..., x_wr_thing: ...); a value starting with ; carries parameters
  # (dtstart: ';TZID=Europe/London:20270601T190000')
  def vevent(**properties)
    lines = properties.map { |key, value| "#{key.to_s.upcase.tr('_', '-')}#{value.start_with?(';') ? '' : ':'}#{value}" }
    "BEGIN:VEVENT\n#{lines.join("\n")}\nEND:VEVENT"
  end

  def meetup(**overrides)
    vevent(uid: 'meetup-1', dtstart: '20270501T180000Z', dtend: '20270501T200000Z', summary: 'Monthly meetup',
           description: 'Bring a friend.', location: 'Hackney, London', url: 'https://events.example.com/meetup', **overrides)
  end

  # Syncs the organisation's feeds, serving body as the feed at url
  def import(organisation, body, url: FEED_URL, requested_urls: nil)
    stub_faraday({ url => { status: 200, body: body } }, requested_urls: requested_urls) do
      organisation.sync_calendar_imports
    end
  end

  # responses: { url => { status:, body:, headers: } }, or { url => exception } to raise it instead. Faraday.get (the
  # feed) and connections from Faraday.new (Luma's event pages) both answer from it, failing on any other URL. Each URL
  # requested is pushed to requested_urls, and its request options (timeouts...) go in request_options by URL. The
  # responses can be given without braces, as keywords
  def stub_faraday(responses = {}, requested_urls: nil, request_options: nil, **more_responses)
    responses = responses.merge(more_responses.transform_keys(&:to_s))
    response_class = Struct.new(:status, :body, :headers) do
      def success?
        status.between?(200, 299)
      end
    end

    responder = lambda do |url, *_args, &block|
      url = url.to_s
      requested_urls&.push(url)
      request = Faraday::Connection.new.build_request(:get) do |req|
        req.url(url)
        block&.call(req)
      end
      request_options&.store(url, request.options)
      response = responses.fetch(url) { raise "Unexpected Faraday.get for #{url}" }
      raise response if response.is_a?(Exception)

      response_class.new(response[:status], response[:body], response[:headers] || {})
    end

    connection_builder = lambda do |*args, **kwargs, &block|
      Faraday::Connection.new(*args, **kwargs) do |f|
        block&.call(f)
        f.adapter :test do |stub|
          responses.each do |url, spec|
            stub.get(url) do |env|
              requested_urls&.push(url)
              request_options&.store(url, env.request)
              raise spec if spec.is_a?(Exception)

              [spec[:status], spec[:headers] || {}, spec[:body]]
            end
          end
        end
      end
    end

    Faraday.stub(:get, responder) do
      Faraday.stub(:new, connection_builder) { yield }
    end
  end
end
