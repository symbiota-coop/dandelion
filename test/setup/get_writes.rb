# A GET or HEAD request must not change the database: the session cookie is SameSite=Lax, so a link from another site,
# or an <img src="/..."> in rich text on our own pages, makes the viewer's browser send one with their session. So while
# the app handles a GET or HEAD, the Mongo write commands it issues are recorded with the route and collection, and a
# test that passes otherwise fails (TestHelpers#check_get_writes) if one isn't in ALLOWED, the writes a GET should make.
#
# Attribution: the middleware marks the thread handling the request (a thread variable, so fibers on it count too), and
# only that thread's commands count. Browser tests run the app on Capybara's server threads while the test thread talks
# to Mongo too, and the test thread's writes are never blamed on a request. A request's own threads (the Thread.new in
# /stats/asn and StatsHelper, which only call outside APIs) aren't marked. A job a GET queues counts as the GET's write
# (the insert into delayed_backend_mongoid_jobs), but what the job writes when a test runs it (run_jobs, on the test
# thread) is the job's, not the request's
module GetWrites
  WRITE_COMMANDS = %w[insert update delete findAndModify create createIndexes drop dropIndexes].freeze
  THREAD_KEY = :get_writes_request

  # The writes a GET should make, each with why. Keep them narrow (collection, and route, fields or params where they
  # matter) so an entry can't hide another write to the same collection. Never add one to make a test pass: an entry is
  # right only when the write is one a GET should make. Otherwise make the route a POST
  #   collection: what's written, or a list; command: optional, one of WRITE_COMMANDS
  #   route: 'GET /path' as the controller writes it (HEAD is the GET's), a Regexp, or a list, optional
  #   fields: for updates, every field the update sets must be one of these, optional
  #   params: the request's query must have one of these, optional

  # What signing someone in writes (sign_in_from_email, start_session!, Account#confirm_email!)
  SIGN_IN_FIELDS = %w[failed_sign_in_attempts password_sign_in_paused_until has_signed_in sign_ins_count link_token session_token
                      legacy_sessions_revoked sign_in_code_digest sign_in_code_nonce sign_in_code_expires_at
                      ended_sessions_for_email_sign_in email_confirmed confirm_email_prompt_owed crypted_password api_key ics_key].freeze
  SIGN_IN_CODE_FIELDS = %w[sign_in_code_digest sign_in_code_nonce sign_in_code_expires_at].freeze

  ALLOWED = [
    { collection: 'page_views', command: 'insert', reason: 'Counting a page view is what viewing the page does' },
    { collection: 'accounts', fields: %w[last_active], reason: 'When the account was last seen, which a page load is' },
    { collection: 'accounts', fields: %w[session_token], reason: 'session_token! makes the token on first use, for sessions from before tokens (session_account)' },
    { collection: 'fragments', command: %w[insert delete], reason: "cp's cache of a partial, filled when it's read, and an expired one removed" },
    { collection: 'account_notification_caches', route: ['GET /', 'GET /notifications'], reason: 'The newsfeed cache, filled when it is read' },
    { collection: 'account_recommendation_caches', route: ['GET /', 'GET /recommendations/events', 'GET /recommendations/people'],
      reason: 'The recommendations cache, filled when it is read' },
    { collection: 'locks', route: ['GET /recommendations/events', 'GET /recommendations/people'],
      reason: 'RecordLock, so one request at a time fills the recommendations cache' },
    { collection: 'stashes', command: 'insert', route: 'GET /e/:slug/feedback_report', reason: 'The feedback report, cached when it is read' },
    { collection: 'events', fields: %w[sold_out_cache sold_out_due_to_sales_end_cache], reason: 'Whether the event is sold out, cached when it is read' },
    { collection: 'events', fields: %w[page_views_count], route: 'GET /e/:slug', reason: "Counting a view of the event's page" },
    { collection: 'locations', fields: %w[events_count], route: 'GET /locations/:name', reason: "The location's count of events, cached when it is read" },
    { collection: 'event_boost_impressions', command: 'insert', route: 'GET /events', reason: 'Counting that a boosted event was shown' },
    { collection: 'dragonfly_jobs', command: 'insert', reason: "An image URL's job, saved when the URL is first made, so the URL can name it" },
    { collection: 'read_receipts', command: 'insert', reason: 'Seeing a comment is what the "N people read this" it shows counts' },
    { collection: 'message_receipts', route: 'GET /messages/:username', reason: 'Opening a thread is reading its messages, which the sender sees as Read' },
    { collection: 'accounts', fields: %w[seen_intro_tour], route: 'GET /', reason: 'The intro tour shows once, so showing it is what marks it seen' },
    # Signing in by a link in an email (link_token, or sign_in_token in old emails) or by a sign in code is a GET by
    # design: the token or code is unguessable and is what authorises it, not the session (app/helpers/sign_in.rb)
    { collection: 'accounts', fields: SIGN_IN_FIELDS, params: %w[link_token sign_in_token sign_in_code], reason: 'Signing in by a link token or sign in code' },
    { collection: %w[sign_ins provider_links], params: %w[link_token sign_in_token sign_in_code], reason: 'Signing in by a link token or sign in code' },
    # OAuth providers send people back with a GET, and OmniAuth checks the state it sent
    { collection: 'accounts', fields: SIGN_IN_FIELDS, route: 'GET /auth/:provider/callback', reason: 'Signing in with a provider' },
    { collection: %w[sign_ins provider_links], route: 'GET /auth/:provider/callback', reason: 'Signing in with a provider' },
    # Emails a sign in code to the account's own address, rate limited (RecipientLimit), which does nothing until it's
    # entered: a page that needs one (verification_required!), or a signed out link naming the account (sign_in_code_required!)
    { collection: 'accounts', fields: SIGN_IN_CODE_FIELDS, route: ['GET /accounts/api_key', 'GET /accounts/delete', 'GET /accounts/password', 'GET /accounts/edit',
                                                                   'GET /accounts/subscriptions', 'GET /accounts/sign_in_code'],
      reason: 'Sending a sign in code to the account, when a page needs one' },
    # Coming back from a payment provider, or the page's poll after it: the order or payment is completed only once the
    # provider (PayPal, Open Collective, the chain) says it was paid, whoever asks, so the request can't steer it
    { collection: %w[orders tickets donations delayed_backend_mongoid_jobs], route: 'GET /e/:slug/orders/:order_id/payment_completed',
      reason: 'Recording a payment the provider says was made' },
    { collection: %w[orders tickets donations delayed_backend_mongoid_jobs], route: 'GET /e/:slug', params: %w[success],
      reason: 'Recording a payment the provider says was made, on coming back from it' },
    { collection: %w[payments gatherings memberships notifications delayed_backend_mongoid_jobs], route: 'GET /g/:slug/payments/:payment_id',
      reason: 'Recording a payment the chain says was made' },
    # Stripe sends people back with a GET: the checkout session is fetched from Stripe and must be this organisation's
    { collection: %w[organisations organisation_contributions delayed_backend_mongoid_jobs], route: 'GET /o/:slug/stripe_setup_complete',
      reason: "Saving the card Stripe's checkout set up" },
    { collection: 'events', fields: %w[browsable], route: 'GET /o/:slug/stripe_setup_complete',
      reason: "Saving the card Stripe's checkout set up pays the organisation up, which lists its events (update_paid_up)" },
    # Stripe Connect's OAuth return, a GET, which only acts on a state token signed for this account and organisation
    { collection: 'organisations', fields: %w[stripe_connect_json stripe_account_json], route: 'GET /organisations/stripe_connect',
      reason: "Connecting the organisation's Stripe account" },
    { collection: 'organisationships', route: 'GET /o/:slug/stripe_connect', reason: "Connecting a member's Stripe account, following the organisation if they don't" },
    { collection: 'accounts', fields: %w[organisation_ids_cache organisation_ids_public_cache subscribed_organisation_ids_cache unsubscribed_organisation_ids_cache],
      route: 'GET /o/:slug/stripe_connect', reason: "Following the organisation updates the member's caches of the organisations they follow" }
  ].freeze

  Write = Struct.new(:test, :route, :collection, :command, :fields, :params, keyword_init: true) do
    def to_s
      "#{route}: #{command} #{collection}#{" (#{fields.join(', ')})" if fields&.any?}"
    end
  end

  LOCK = Mutex.new

  class << self
    attr_reader :writes

    def start(test)
      LOCK.synchronize do
        @test = test
        @writes = []
      end
    end

    def current_test
      LOCK.synchronize { @test }
    end

    def record(write)
      LOCK.synchronize { @writes << write if write.test == @test }
    end

    def disallowed
      LOCK.synchronize { @writes.dup }.reject { |write| allowed?(write) }.uniq(&:to_s)
    end

    def allowed?(write)
      ALLOWED.any? { |entry| matches?(entry, write) }
    end

    def matches?(entry, write)
      return false unless Array(entry[:collection]).include?(write.collection)
      return false if entry[:command] && !Array(entry[:command]).include?(write.command)
      return false if entry[:route] && Array(entry[:route]).none? { |route| route === write.route }
      return false if entry[:fields] && !(write.fields && (write.fields - entry[:fields]).empty?)
      return false if entry[:params] && !entry[:params].intersect?(write.params)

      true
    end

    # Mongo's command monitoring, which the driver calls on the thread that sends the command
    def started(event)
      request = Thread.current.thread_variable_get(THREAD_KEY)
      return unless request

      command = event.command
      name = event.command_name.to_s
      return unless WRITE_COMMANDS.include?(name) || (name == 'aggregate' && aggregate_writes?(command))

      request[:writes] << { collection: command[name].to_s, command: name, fields: fields_of(name, command) }
    end

    def succeeded(_event); end

    def failed(_event); end

    private

    def aggregate_writes?(command)
      Array(command['pipeline']).any? { |stage| stage.key?('$out') || stage.key?('$merge') }
    end

    # The fields an update or findAndModify sets: the keys under its operators, or a replacement's own keys
    def fields_of(name, command)
      updates = case name
                when 'update' then Array(command['updates']).map { |update| update['u'] }
                when 'findAndModify' then [command['update']].compact
                else return
                end
      updates.flat_map do |update|
        if update.is_a?(Array) # an aggregation pipeline
          update.flat_map { |stage| stage.values.flat_map { |value| value.is_a?(Hash) ? value.keys : [] } }
        elsif update.keys.any? { |key| key.to_s.start_with?('$') }
          update.values.flat_map { |value| value.is_a?(Hash) ? value.keys : [] }
        else
          update.keys
        end
      end.map { |field| field.to_s.split('.').first }.uniq
    end
  end

  # Outside the app and its own middleware, so writes anywhere in the request count
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless %w[GET HEAD].include?(env['REQUEST_METHOD'])

      test = GetWrites.current_test
      request = { writes: [] }
      previous = Thread.current.thread_variable_get(THREAD_KEY)
      Thread.current.thread_variable_set(THREAD_KEY, request)
      begin
        @app.call(env)
      ensure
        Thread.current.thread_variable_set(THREAD_KEY, previous)
        report(env, test, request[:writes]) if request[:writes].any?
      end
    end

    private

    # The route the app matched, which Padrino sets before the app's own before filters run (they can redirect before a
    # later filter would see it)
    def report(env, test, writes)
      app = Thread.current['padrino.instance']
      route = app.request.route_obj if app.respond_to?(:request) && app.request&.env.equal?(env)
      route = route ? RouteRecording.route_name(route) : "#{env['REQUEST_METHOD']} #{env['PATH_INFO']} (no route)"
      params = Rack::Utils.parse_query(env['QUERY_STRING'].to_s).keys
      writes.each do |write|
        GetWrites.record(Write.new(test: test, route: route, params: params, **write))
      end
    end
  end
end

Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, GetWrites)
Padrino.use GetWrites::Middleware
