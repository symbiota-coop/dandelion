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

    AUTH_REQUIRED_MESSAGE = 'Authentication required. Provide your API key as a Bearer token.'.freeze
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
      # Searches leave out secret events, but the buyer can give their slug or link, as for booking
      record ||= Event.live.secret.find_by(slug: event_slug_from(finder_value)) if model_class == Event && id.blank? && finder_value.present?

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

    # The event a booking tool is for, by slug or id. A secret event is found only by its slug, or a link with it in, as
    # the event page is: the link is what keeps it secret, so it's never found by id, and searches leave it out
    def self.bookable_event(slug: nil, id: nil)
      return Event.live.publicly_visible.find(id.to_s) if id.present?

      slug = event_slug_from(slug)
      return if slug.empty?

      Event.live.find_by(slug: slug) || Event.live.publicly_visible.find_by_slug_or_id(slug: slug)
    end

    # The slug itself, or the one in a link to the event (https://dandelion.events/e/slug?ticket_type_id=...)
    def self.event_slug_from(value)
      value = value.to_s.strip
      value[%r{/e/([^/?#]+)}, 1] || value
    end

    # secret_ticket_type_id lists the hidden ticket type its secret link unlocks, and discount_code says what the code
    # takes off, as the checkout form shows once a code is applied
    def self.perform_get_event_checkout_requirements(slug: nil, id: nil, secret_ticket_type_id: nil, discount_code: nil)
      return tool_error('Provide event slug or id') if slug.blank? && id.blank?

      event = bookable_event(slug: slug, id: id)
      return tool_error('Event not found') unless event

      secret_ticket_type_id = secret_ticket_type_id_from(secret_ticket_type_id)
      secret_ticket_type = event.secret_ticket_type(secret_ticket_type_id)
      return tool_error("That secret link doesn't unlock a ticket type of this event. Check the link with the buyer.") if secret_ticket_type_id && !secret_ticket_type

      requirements = event.checkout_requirements(secret_ticket_type: secret_ticket_type)
      requirements[:discount_code] = checkout_discount_code_details(event, discount_code, requirements[:ticket_types]) unless discount_code.to_s.strip.empty?
      tool_json(requirements)
    end

    def self.checkout_discount_code_details(event, code, ticket_types)
      discount_code, problem = event.checkout_discount_code(code)
      return { code: code.to_s.strip.upcase, valid: false, problem: problem.to_s } unless discount_code

      {
        code: discount_code.code,
        valid: true,
        percentage_discount: discount_code.percentage_discount,
        fixed_discount: discount_code.fixed_discount_amount,
        fixed_discount_currency: discount_code.fixed_discount_currency,
        # The fixed discount comes off the order's total, and the percentage off each ticket, of these ticket types only
        ticket_type_ids: ticket_types.pluck(:id).select { |ticket_type_id| discount_code.applies_to_ticket_type?(event.ticket_types.find(ticket_type_id)) }
      }
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

    def self.perform_get_organisation_orders(server_context: nil, slug: nil, id: nil)
      with_organisation_admin(server_context, slug: slug, id: id) do |account, organisation|
        tool_json(organisation.admin_orders.map { |order| order.api_hash(account) })
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
          description 'Get what booking a Dandelion event involves, by slug or ID: whether it can be booked, its ticket types with prices, availability and waitlists, the buyer details and questions the checkout form asks for, opt-ins, any donation it offers, whether it takes discount codes, terms and the payment methods on offer. Pass a secret_ticket_type_id to list the hidden ticket type its link unlocks, and a discount_code to see what it takes off. Call this before create_checkout_tool or join_waitlist_tool.'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Event slug, or a link to the event. A secret event is only found by its slug or link, as the buyer has it' },
                         id: { type: 'string', description: 'Event ID' },
                         secret_ticket_type_id: { type: 'string', description: "A hidden ticket type's secret link, or the ticket_type_id in its query string" },
                         discount_code: { type: 'string', description: 'A discount code the buyer has' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |slug: nil, id: nil, secret_ticket_type_id: nil, discount_code: nil, _server_context: {}, **_rest|
            Dandelion::MCP.perform_get_event_checkout_requirements(slug: slug, id: id, secret_ticket_type_id: secret_ticket_type_id, discount_code: discount_code)
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'create_checkout_tool'
          title 'Create Checkout'
          description "Book tickets to a Dandelion event: for the authenticated account with a Bearer API key, or without one for the buyer given. Free bookings are confirmed straight away; paid ones return a checkout_url where the buyer pays, which they must open themselves before pay_by, when unpaid orders are released. Call get_event_checkout_requirements_tool first, and confirm the tickets, prices, any donation and discount, the total and any terms with the buyer before calling this. Where the donation goes to Dandelion (added_by_default), the booking includes its suggested donation unless you pass donation_amount, as the checkout form does: include it in the total you tell the buyer, say it's optional, and pass 0 if they don't want it. Range and pay-what-you-want tickets need the price the buyer chose, in prices: never choose one for them. When the buyer has to finish on the event page, the error links to it with their choices filled in."
          input_schema(properties: {
                         slug: { type: 'string', description: 'Event slug, or a link to the event. A secret event is only found by its slug or link, as the buyer has it' },
                         id: { type: 'string', description: 'Event ID' },
                         quantities: { type: 'object', description: 'Ticket type id => number of tickets', additionalProperties: { type: 'integer' } },
                         prices: { type: 'object', description: 'Ticket type id => the price per ticket the buyer chose, for range (within price_min and price_max) and pay_what_you_want ticket types', additionalProperties: { type: 'number' } },
                         answers: { type: 'object', description: 'Question index => answer: a string, true/false for a checkbox, or an array of options for checkboxes' },
                         accept_terms: { type: 'boolean', description: 'The buyer has accepted the terms and conditions (required when terms.must_accept)' },
                         idempotency_key: { type: 'string', description: 'A unique key for this booking. Retrying with the same key returns the first order instead of booking again (status processing while it is still being set up)' },
                         buyer: {
                           type: 'object',
                           description: 'Who the tickets are for, with the fields buyer_fields lists. Required without an API key; with one, the booking is for that account, whose phone, postcode and country the details given update',
                           properties: { name: { type: 'string' }, email: { type: 'string' }, phone: { type: 'string' }, postcode: { type: 'string' }, country: { type: 'string' },
                                         hear_about: { type: 'string' } }
                         },
                         opt_ins: { type: 'array', items: { type: 'string' }, description: 'The names of the opt_ins the buyer chose, from get_event_checkout_requirements_tool' },
                         discount_code: { type: 'string', description: 'A discount code the buyer has' },
                         payment_method: { type: 'string', description: 'The payment method the buyer chose, from the payment_methods with agent_checkout. Defaults to the first one that pays by link' },
                         secret_ticket_type_id: { type: 'string', description: "A hidden ticket type's secret link, or the ticket_type_id in its query string, to book that ticket type" },
                         donation_amount: { type: 'number', description: "A donation the buyer chose to add, where the requirements list a donation: at least its minimum, if it has one (needed when required, and otherwise only if the buyer gives one). Left out for a donation to Dandelion, the booking adds the suggested one: suggested_percent of the tickets after percentage discounts (higher_price's suggested_percent above its over), and at least the minimum. 0 for none" },
                         confirm_duplicate: { type: 'boolean', description: 'The buyer confirmed they want to book again, though this account already has a ticket' },
                         confirm_email: { type: 'boolean', description: "The buyer confirmed their email address is right, though it looks mistyped (a slip from a common provider's)" },
                         attribution: {
                           type: 'object',
                           description: 'From the query string of the event link the buyer followed, if it has them',
                           properties: CHECKOUT_ATTRIBUTION_FIELDS.index_with { { type: 'string' } }
                         }
                       }, required: [:quantities])
          annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

          # **_rest ignores arguments the tool doesn't take, rather than failing the call
          define_singleton_method(:call) do |slug: nil, id: nil, quantities: nil, prices: nil, answers: nil, accept_terms: false, idempotency_key: nil, buyer: nil, opt_ins: nil,
                                             discount_code: nil, payment_method: nil, secret_ticket_type_id: nil, donation_amount: nil, confirm_duplicate: false,
                                             confirm_email: false, attribution: nil, server_context: {}, **_rest|
            Dandelion::MCP.perform_create_checkout(server_context: server_context, slug: slug, id: id, quantities: quantities, prices: prices, answers: answers,
                                                   accept_terms: accept_terms, idempotency_key: idempotency_key, buyer: buyer, opt_ins: opt_ins,
                                                   discount_code: discount_code, payment_method: payment_method, secret_ticket_type_id: secret_ticket_type_id,
                                                   donation_amount: donation_amount, confirm_duplicate: confirm_duplicate, confirm_email: confirm_email,
                                                   attribution: attribution)
          end
        end,
        Class.new(::MCP::Tool) do
          tool_name 'join_waitlist_tool'
          title 'Join Waitlist'
          description "Join the waitlist for a sold-out ticket type of a Dandelion event (one get_event_checkout_requirements_tool lists with waitlist true), or for the event itself when event_waitlist is true: for the authenticated account with a Bearer API key, or without one for the buyer given. They're emailed when tickets become available. Check with the buyer before calling this."
          input_schema(properties: {
                         slug: { type: 'string', description: 'Event slug, or a link to the event. A secret event is only found by its slug or link, as the buyer has it' },
                         id: { type: 'string', description: 'Event ID' },
                         ticket_type_id: { type: 'string', description: "The sold-out ticket type's id. Leave it out to join the event's waitlist" },
                         buyer: {
                           type: 'object',
                           description: 'Who is joining the waitlist. Required without an API key',
                           properties: { name: { type: 'string' }, email: { type: 'string' } }
                         }
                       })
          annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: true)

          define_singleton_method(:call) do |slug: nil, id: nil, ticket_type_id: nil, buyer: nil, server_context: {}, **_rest|
            Dandelion::MCP.perform_join_waitlist(server_context: server_context, slug: slug, id: id, ticket_type_id: ticket_type_id, buyer: buyer)
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
          tool_name 'get_organisation_orders_tool'
          title 'Get Organisation Orders'
          description 'Get the 100 most recently completed orders across all events hosted or cohosted by an organisation you admin, by slug or ID. Requires a Bearer API key.'
          input_schema(properties: {
                         slug: { type: 'string', description: 'Organisation slug' },
                         id: { type: 'string', description: 'Organisation ID' }
                       })
          annotations(read_only_hint: true, destructive_hint: false)

          define_singleton_method(:call) do |slug: nil, id: nil, server_context: {}|
            Dandelion::MCP.perform_get_organisation_orders(server_context: server_context, slug: slug, id: id)
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
          instructions: 'Tools for querying Dandelion accounts, events, organisations and gatherings, and for booking events. To book: get_event_checkout_requirements_tool, confirm the details with the buyer, create_checkout_tool (as the authenticated account, or for the buyer given without an API key), then send the buyer to the checkout_url to pay. For a sold-out event or ticket type, join_waitlist_tool. Authenticated tools such as get_me_tool, get_organisation_events_tool, get_organisation_followers_tool, get_organisation_orders_tool, get_event_orders_tool and get_event_tickets_tool require a Bearer API key.',
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
