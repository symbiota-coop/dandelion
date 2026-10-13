module Dandelion
  module MCP
    MODEL_CONFIGS = {
      'Event' => {
        finder_field: :slug,
        search_fields: ->(e) { { id: e.id.to_s, name: e.name, slug: e.slug, url: "#{ENV['BASE_URI']}/e/#{e.slug}", start_time: e.start_time, end_time: e.end_time, location: e.location } },
        get_fields: ->(e) { e.public_data.merge(currency: e.currency, ticket_types: e.public_ticket_types) },
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

    AUTH_REQUIRED_MESSAGE = 'Authentication required. Provide your API key as a Bearer token.'
    BEARER_PATTERN = /\ABearer\s+(\S+)\z/i

    def self.config_for(model_class)
      MODEL_CONFIGS[model_class.name]
    end

    def self.perform_search(model_class, query, limit: nil)
      limit = (limit || 20).to_i.clamp(1, 100)
      config = config_for(model_class)
      scope = model_class.search_scope
      results = model_class.search(query, scope, limit: limit, build_records: true, phrase_boost: 1.5, fuzzy_text: true, vector_weight: 0.5)
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

    def self.perform_get_event_checkout_requirements(slug: nil, id: nil)
      return tool_error('Provide event slug or id') if slug.blank? && id.blank?

      event = Event.live.publicly_visible.find_by_slug_or_id(slug: slug, id: id)
      return tool_error('Event not found') unless event

      tool_json(event.checkout_requirements)
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

    def self.account_from_request(rack_request)
      header = rack_request.get_header('HTTP_AUTHORIZATION')
      return nil if header.blank?

      match = header.match(BEARER_PATTERN)
      return :invalid unless match

      Account.find_by(api_key: match[1]) || :invalid
    end

    def self.unauthorized_response
      [
        401,
        {
          'Content-Type' => 'application/json',
          'WWW-Authenticate' => 'Bearer'
        },
        [{ error: 'invalid_token', error_description: 'Invalid API key' }.to_json]
      ]
    end

    def self.current_account_from(server_context)
      return unless server_context.respond_to?(:[])

      server_context[:current_account]
    end

    def self.tool_text(text, error: false)
      ::MCP::Tool::Response.new([{ type: 'text', text: text }], error: error)
    end

    def self.tool_json(payload)
      tool_text(payload.to_json)
    end

    def self.tool_error(message)
      tool_text(message, error: true)
    end

    def self.with_account(server_context)
      account = current_account_from(server_context)
      return yield(account) if account

      tool_error(AUTH_REQUIRED_MESSAGE)
    end

    def self.with_event_admin(server_context, slug: nil, id: nil)
      with_account(server_context) do |account|
        if slug.blank? && id.blank?
          next tool_error('Provide event slug or id')
        end

        event = Event.find_by_slug_or_id(slug: slug, id: id)
        next tool_error('Event not found') unless event
        next tool_error('You do not have access to this event') unless Event.admin?(event, account)

        yield(account, event)
      end
    end

    def self.with_organisation_admin(server_context, slug: nil, id: nil)
      with_account(server_context) do |account|
        if slug.blank? && id.blank?
          next tool_error('Provide organisation slug or id')
        end

        organisation = Organisation.find_by_slug_or_id(slug: slug, id: id)
        next tool_error('Organisation not found') unless organisation
        next tool_error('You do not have access to this organisation') unless Organisation.admin?(organisation, account)

        yield(account, organisation)
      end
    end

    def self.perform_get_me(server_context: nil)
      with_account(server_context) do |account|
        tool_json(account.api_hash)
      end
    end

    def self.perform_get_organisation_events(server_context: nil, slug: nil, id: nil)
      with_organisation_admin(server_context, slug: slug, id: id) do |_account, organisation|
        tool_json(organisation.admin_events.map(&:admin_list_hash))
      end
    end

    def self.perform_get_organisation_followers(server_context: nil, slug: nil, id: nil)
      with_organisation_admin(server_context, slug: slug, id: id) do |_account, organisation|
        tool_json(organisation.recent_followers.map(&:api_hash))
      end
    end

    def self.perform_get_event_orders(server_context: nil, slug: nil, id: nil)
      with_event_admin(server_context, slug: slug, id: id) do |account, event|
        tool_json(event.admin_orders.map { |order| order.api_hash(account) })
      end
    end

    def self.perform_get_event_tickets(server_context: nil, slug: nil, id: nil)
      with_event_admin(server_context, slug: slug, id: id) do |account, event|
        tool_json(event.admin_tickets.map { |ticket| ticket.api_hash(account) })
      end
    end

    def self.perform_get_upcoming_organisation_events(slug: nil, id: nil, from: nil, to: nil, limit: nil)
      return ::MCP::Tool::Response.new([{ type: 'text', text: 'Provide organisation slug or id' }], error: true) if slug.blank? && id.blank?

      organisation = Organisation.find_by_slug_or_id(slug: slug, id: id)

      return ::MCP::Tool::Response.new([{ type: 'text', text: 'Organisation not found' }], error: true) unless organisation

      from_date = from.present? ? parse_date(from) : Date.today
      to_date = to.present? ? parse_date(to) : nil
      return ::MCP::Tool::Response.new([{ type: 'text', text: 'Invalid from or to date format' }], error: true) if (from.present? && from_date.nil?) || (to.present? && to_date.nil?)

      limit = (limit || 20).to_i.clamp(1, 100)
      events = organisation.events_including_cohosted
                           .live
                           .publicly_visible
                           .future_current_evergreen(from_date)
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
          tool_name 'get_event_checkout_requirements_tool'
          title 'Get Event Checkout Requirements'
          description 'Get what booking a Dandelion event involves, by slug or ID: whether it can be booked, its ticket types with prices and availability, the buyer details and questions the checkout form asks for, opt-ins, terms and the payment methods on offer. Call this before create_checkout_tool.'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Event slug' },
                         id: { type: 'string', description: 'Event ID' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |slug: nil, id: nil, _server_context: {}|
            Dandelion::MCP.perform_get_event_checkout_requirements(slug: slug, id: id)
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'create_checkout_tool'
          title 'Create Checkout'
          description 'Book tickets to a Dandelion event for the authenticated account. Free bookings are confirmed straight away; paid ones return a checkout_url where the buyer pays, which they must open themselves before pay_by, when unpaid orders are released. Call get_event_checkout_requirements_tool first, and confirm the tickets, total and any terms with the buyer before calling this. Requires a Bearer API key.'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Event slug' },
                         id: { type: 'string', description: 'Event ID' },
                         quantities: { type: 'object', description: 'Ticket type id => number of tickets', additionalProperties: { type: 'integer' } },
                         prices: { type: 'object', description: 'Ticket type id => price per ticket, for range and pay-what-you-want ticket types', additionalProperties: { type: 'number' } },
                         answers: { type: 'object', description: 'Question index => answer: a string, true/false for a checkbox, or an array of options for checkboxes' },
                         payment_method: { type: 'string', description: 'A payment method name with agent_checkout true. Defaults to the first one on offer' },
                         accept_terms: { type: 'boolean', description: 'The buyer has accepted the terms and conditions (required when terms.must_accept)' },
                         phone: { type: 'string', description: 'Buyer phone number, starting with + and the country code' },
                         hear_about: { type: 'string', description: 'How the buyer heard about the event' },
                         opt_in_organisation: { type: 'boolean', description: 'The buyer wants email updates from the organisation' },
                         opt_in_facilitator: { type: 'boolean', description: 'The buyer wants email updates from the facilitators' },
                         confirm_duplicate: { type: 'boolean', description: 'Book even though this account already has a ticket to the event' },
                         idempotency_key: { type: 'string', description: 'A unique key for this booking. Retrying with the same key returns the first order instead of booking again' }
                       }, required: [:quantities])
          annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

          define_singleton_method(:call) do |server_context: {}, **args|
            Dandelion::MCP.perform_create_checkout(server_context: server_context, **args.slice(*Dandelion::MCP::CHECKOUT_ARGS))
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'get_order_status_tool'
          title 'Get Order Status'
          description 'Get the status of an order made with create_checkout_tool (awaiting_payment, complete or expired), with its tickets, total and checkout_url. Works for the order\'s buyer and the event\'s admins. Requires a Bearer API key.'
          input_schema(properties: {
                         order_id: { type: 'string', description: 'Order ID' }
                       }, required: [:order_id])
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |order_id: nil, server_context: {}|
            Dandelion::MCP.perform_get_order_status(server_context: server_context, order_id: order_id)
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
        end,
        Class.new(::MCP::Tool) do
          tool_name 'get_me_tool'
          title 'Get Me'
          description 'Get the authenticated Dandelion account. Requires a Bearer API key.'
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |server_context: {}|
            Dandelion::MCP.perform_get_me(server_context: server_context)
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'get_organisation_events_tool'
          title 'Get Organisation Events'
          description 'Get all events hosted or cohosted by an organisation you admin, by slug or ID. Requires a Bearer API key.'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Organisation slug' },
                         id: { type: 'string', description: 'Organisation ID' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |slug: nil, id: nil, server_context: {}|
            Dandelion::MCP.perform_get_organisation_events(server_context: server_context, slug: slug, id: id)
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'get_organisation_followers_tool'
          title 'Get Organisation Followers'
          description 'Get organisation followers from the last 24 hours for an organisation you admin, by slug or ID. Requires a Bearer API key.'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Organisation slug' },
                         id: { type: 'string', description: 'Organisation ID' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |slug: nil, id: nil, server_context: {}|
            Dandelion::MCP.perform_get_organisation_followers(server_context: server_context, slug: slug, id: id)
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'get_event_orders_tool'
          title 'Get Event Orders'
          description 'Get all completed orders for a Dandelion event you admin, by slug or ID. Requires a Bearer API key.'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Event slug' },
                         id: { type: 'string', description: 'Event ID' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |slug: nil, id: nil, server_context: {}|
            Dandelion::MCP.perform_get_event_orders(server_context: server_context, slug: slug, id: id)
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'get_event_tickets_tool'
          title 'Get Event Tickets'
          description 'Get all completed tickets for a Dandelion event you admin, by slug or ID. Requires a Bearer API key.'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Event slug' },
                         id: { type: 'string', description: 'Event ID' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |slug: nil, id: nil, server_context: {}|
            Dandelion::MCP.perform_get_event_tickets(server_context: server_context, slug: slug, id: id)
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
          instructions: 'Tools for querying Dandelion accounts, events, organisations and gatherings, and for booking events. To book: get_event_checkout_requirements_tool, confirm the details with the buyer, create_checkout_tool, then send the buyer to the checkout_url to pay and check get_order_status_tool. Authenticated tools such as get_me_tool, create_checkout_tool, get_order_status_tool, get_organisation_events_tool, get_organisation_followers_tool, get_event_orders_tool and get_event_tickets_tool require a Bearer API key.',
          tools: tools
        )
        def s.server_context
          Thread.current[:mcp_server_context]
        end

        def s.server_context=(value)
          Thread.current[:mcp_server_context] = value
        end

        ::MCP::Server::Transports::StreamableHTTPTransport.new(
          s,
          stateless: true,
          allowed_hosts: allowed_hosts,
          dns_rebinding_protection: false
        )
        s
      end
    end

    def self.allowed_hosts
      host = begin
        URI.parse(ENV['BASE_URI'].to_s).host
      rescue URI::InvalidURIError
        nil
      end
      [host].compact
    end

    def self.http_transport
      server.transport
    end

    def self.handle_http_request(rack_request)
      account = account_from_request(rack_request)
      return unauthorized_response if account == :invalid

      server.server_context = { current_account: account }
      http_transport.handle_request(rack_request)
    ensure
      server.server_context = nil
    end
  end
end
