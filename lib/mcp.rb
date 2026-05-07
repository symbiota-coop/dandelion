module Dandelion
  module MCP
    MODEL_CONFIGS = {
      'Event' => {
        finder_field: :slug,
        search_fields: ->(e) { { id: e.id.to_s, name: e.name, slug: e.slug, url: "#{ENV['BASE_URI']}/e/#{e.slug}", start_time: e.start_time, end_time: e.end_time, location: e.location } },
        get_fields: lambda(&:public_data),
        search_description: 'Search recent and upcoming Dandelion events.'
      },
      'Account' => {
        finder_field: :username,
        fields: ->(a) { { id: a.id.to_s, name: a.name, username: a.username, url: "#{ENV['BASE_URI']}/u/#{a.username}" } },
        search_description: 'Search Dandelion accounts.'
      },
      'Organisation' => {
        finder_field: :slug,
        fields: ->(o) { { id: o.id.to_s, name: o.name, slug: o.slug, url: "#{ENV['BASE_URI']}/o/#{o.slug}" } },
        search_description: 'Search Dandelion organisations.'
      },
      'Gathering' => {
        finder_field: :slug,
        fields: ->(g) { { id: g.id.to_s, name: g.name, slug: g.slug, url: "#{ENV['BASE_URI']}/g/#{g.slug}" } },
        search_description: 'Search Dandelion gatherings.'
      }
    }.freeze

    def self.config_for(model_class)
      MODEL_CONFIGS[model_class.name]
    end

    def self.perform_search(model_class, query, limit: nil)
      limit = (limit || 20).to_i.clamp(1, 100)
      config = config_for(model_class)
      scope = model_class.search_scope
      results = model_class.search(query, scope, limit: limit, build_records: true, phrase_boost: 1.5, text_search: true, vector_weight: 0.5)
      fields_proc = config[:search_fields] || config[:fields]
      ::MCP::Tool::Response.new([{ type: 'text', text: results.map { |r| fields_proc.call(r) }.to_json }])
    end

    def self.perform_get(model_class, id: nil, **finder_args)
      config = config_for(model_class)
      scope = model_class.search_scope
      scope = scope.with_key_includes if scope.respond_to?(:with_key_includes)
      finder_value = finder_args[config[:finder_field]]

      record = if id.present?
                 scope.find(id)
               elsif finder_value.present?
                 scope.find_by(config[:finder_field] => finder_value)
               end

      return ::MCP::Tool::Response.new([{ type: 'text', text: "#{model_class.name} not found" }], error: true) unless record

      fields_proc = config[:get_fields] || config[:fields]
      result = fields_proc.call(record)
      ::MCP::Tool::Response.new([{ type: 'text', text: result.to_json }])
    end

    def self.parse_date(date)
      Date.parse(date)
    rescue Date::Error
      nil
    end

    def self.perform_get_trending_events(limit: nil)
      limit = (limit || 20).to_i.clamp(1, 100)

      events = Event.live.publicly_visible.browsable
                    .future
                    .trending(limit: limit)

      config = config_for(Event)
      fields_proc = config[:search_fields] || config[:fields]
      result = events.map { |e| fields_proc.call(e) }
      ::MCP::Tool::Response.new([{ type: 'text', text: result.to_json }])
    end

    def self.perform_get_upcoming_organisation_events(slug: nil, id: nil, from: nil, to: nil, limit: nil)
      return ::MCP::Tool::Response.new([{ type: 'text', text: 'Provide organisation slug or id' }], error: true) if slug.blank? && id.blank?

      organisation = if id.present?
                       Organisation.find(id)
                     elsif slug.present?
                       Organisation.find_by(slug: slug)
                     end

      return ::MCP::Tool::Response.new([{ type: 'text', text: 'Organisation not found' }], error: true) unless organisation

      from_date = from.present? ? parse_date(from) : Date.today
      to_date = to.present? ? parse_date(to) : nil
      return ::MCP::Tool::Response.new([{ type: 'text', text: 'Invalid from or to date format' }], error: true) if (from.present? && from_date.nil?) || (to.present? && to_date.nil?)

      limit = (limit || 20).to_i.clamp(1, 100)
      events = organisation.events_including_cohosted
                           .live
                           .publicly_visible
                           .future_and_current(from_date)
                           .order('start_time asc')
                           .limit(limit)
      events = events.and(:start_time.lt => to_date + 1) if to_date

      config = config_for(Event)
      fields_proc = config[:search_fields] || config[:fields]
      result = events.map { |e| fields_proc.call(e) }
      ::MCP::Tool::Response.new([{ type: 'text', text: result.to_json }])
    end

    # Generate Search and Get tools from MODEL_CONFIGS (lazy loaded)
    def self.tools
      @tools ||= [
        *MODEL_CONFIGS.flat_map do |model_name, config|
          finder_field = config[:finder_field]

          search_tool = Class.new(::MCP::Tool) do
            title "Search #{model_name.pluralize}"
            description config[:search_description]
            input_schema(properties: {
                           query: { type: 'string', description: 'Search term' },
                           limit: { type: 'integer', description: 'Max results (default 20, max 100)' }
                         }, required: [:query])
            annotations(read_only_hint: true, destructive_hint: false)

            define_singleton_method(:call) do |query:, limit: nil, _server_context: {}|
              Dandelion::MCP.perform_search(model_name.constantize, query, limit: limit)
            end
          end
          const_set("Search#{model_name.pluralize}Tool", search_tool)

          get_tool = Class.new(::MCP::Tool) do
            title "Get #{model_name}"
            description "Get a Dandelion #{model_name.downcase} by #{finder_field} or ID."
            input_schema(properties: {
                           finder_field => { type: 'string', description: "#{model_name} #{finder_field}" },
                           id: { type: 'string', description: "#{model_name} ID" }
                         })
            annotations(read_only_hint: true, destructive_hint: false)

            define_singleton_method(:call) do |id: nil, _server_context: {}, **finder_args|
              Dandelion::MCP.perform_get(model_name.constantize, id: id, **finder_args)
            end
          end
          const_set("Get#{model_name}Tool", get_tool)

          [search_tool, get_tool]
        end,
        Class.new(::MCP::Tool) do
          tool_name 'get_organisation_upcoming_events_tool'
          title 'Get Organisation Upcoming Events'
          description 'Get upcoming events for a Dandelion organisation by slug or ID. Optionally filter by from and to dates (YYYY-MM-DD).'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Organisation slug' },
                         id: { type: 'string', description: 'Organisation ID' },
                         from: { type: 'string', description: 'Start date for events (YYYY-MM-DD). Defaults to today.' },
                         to: { type: 'string', description: 'End date for events (YYYY-MM-DD). Optional.' },
                         limit: { type: 'integer', description: 'Max results (default 20, max 100)' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |slug: nil, id: nil, from: nil, to: nil, limit: nil, _server_context: {}|
            Dandelion::MCP.perform_get_upcoming_organisation_events(slug: slug, id: id, from: from, to: to, limit: limit)
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'get_trending_events_tool'
          title 'Get Trending Events'
          description 'Get trending Dandelion events.'
          input_schema(properties: {
                         limit: { type: 'integer', description: 'Max results (default 20, max 100)' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |limit: nil, _server_context: {}|
            Dandelion::MCP.perform_get_trending_events(limit: limit)
          end
        end
      ].freeze
    end

    def self.server
      @server ||= begin
        s = ::MCP::Server.new(
          name: 'dandelion',
          title: 'Dandelion',
          version: '1.0.0',
          instructions: 'Tools for querying Dandelion accounts, events, organisations and gatherings.',
          tools: tools
        )
        transport = ::MCP::Server::Transports::StreamableHTTPTransport.new(s, stateless: true)
        s.transport = transport
        s
      end
    end

    def self.http_transport
      server.transport
    end

    def self.handle_http_request(rack_request)
      http_transport.handle_request(rack_request)
    end
  end
end
