module Dandelion
  module MCP
    CONFIG = {
      Event => {
        scope: -> { Event.live.publicly_visible.browsable.future(1.week.ago).with_public_includes },
        finder_field: :slug,
        fields: lambda(&:public_data),
        post_process: ->(results) { results.uniq { |e| [e.name, e.location] } },
        search_description: 'Search recent and upcoming Dandelion events.'
      },
      Account => {
        scope: -> { Account.publicly_visible },
        finder_field: :username,
        fields: ->(a) { { id: a.id.to_s, name: a.name, username: a.username, location: a.location, bio: a.bio } },
        search_description: 'Search Dandelion accounts.'
      },
      Organisation => {
        scope: -> { Organisation.all },
        finder_field: :slug,
        fields: ->(o) { { id: o.id.to_s, name: o.name, slug: o.slug, intro: o.intro_text } },
        search_description: 'Search Dandelion organisations.'
      },
      Gathering => {
        scope: -> { Gathering.and(listed: true).and(:privacy.ne => 'secret') },
        finder_field: :slug,
        fields: ->(g) { { id: g.id.to_s, name: g.name, slug: g.slug, intro: g.intro } },
        search_description: 'Search Dandelion gatherings.'
      }
    }.freeze

    def self.perform_search(model_class, query)
      config = CONFIG[model_class]
      scope = config[:scope].call
      results = model_class.search(query, scope, build_records: true, phrase_boost: 1.5, text_search: true, vector_weight: 0.5)
      results = config[:post_process].call(results) if config[:post_process]
      ::MCP::Tool::Response.new([{ type: 'text', text: results.map { |r| config[:fields].call(r) }.to_json }])
    end

    def self.perform_get(model_class, id: nil, **finder_args)
      config = CONFIG[model_class]
      scope = config[:scope].call
      finder_value = finder_args[config[:finder_field]]

      record = if id.present?
                 scope.find(id)
               elsif finder_value.present?
                 scope.find_by(config[:finder_field] => finder_value)
               end

      return ::MCP::Tool::Response.new([{ type: 'text', text: "#{model_class.name} not found" }], is_error: true) unless record

      result = config[:fields].call(record)
      ::MCP::Tool::Response.new([{ type: 'text', text: result.to_json }])
    end

    # Generate Search and Get tools from CONFIG
    TOOLS = CONFIG.flat_map do |model_class, config|
      model_name = model_class.name
      finder_field = config[:finder_field]

      search_tool = Class.new(::MCP::Tool) do
        title "Search #{model_name.pluralize}"
        description config[:search_description]
        input_schema(properties: { query: { type: 'string', description: 'Search term' } }, required: [:query])
        annotations(read_only_hint: true, destructive_hint: false)

        define_singleton_method(:call) do |query:, _server_context: {}|
          Dandelion::MCP.perform_search(model_class, query)
        end
      end
      const_set("Search#{model_name.pluralize}Tool", search_tool)

      get_tool = Class.new(::MCP::Tool) do
        title "Get #{model_name}"
        description "Get a Dandelion #{model_name.downcase} by #{finder_field} or ID."
        input_schema(properties: {
                       finder_field => { type: 'string', description: "#{model_name} #{finder_field}" },
                       id: { type: 'string', description: "#{model_name} ID (BSON)" }
                     })
        annotations(read_only_hint: true, destructive_hint: false)

        define_singleton_method(:call) do |id: nil, _server_context: {}, **finder_args|
          Dandelion::MCP.perform_get(model_class, id: id, **finder_args)
        end
      end
      const_set("Get#{model_name}Tool", get_tool)

      [search_tool, get_tool]
    end.freeze

    SERVER = ::MCP::Server.new(
      name: 'dandelion',
      title: 'Dandelion',
      version: '1.0.0',
      instructions: 'Tools for querying Dandelion accounts, events, organisations, and gatherings.',
      tools: TOOLS
    )

    HTTP_TRANSPORT = ::MCP::Server::Transports::StreamableHTTPTransport.new(SERVER, stateless: true)
    SERVER.transport = HTTP_TRANSPORT

    def self.handle_http_request(rack_request)
      HTTP_TRANSPORT.handle_request(rack_request)
    end
  end
end
