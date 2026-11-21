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
  #   collection: what's written; command: optional, one of WRITE_COMMANDS
  #   route: 'GET /path' as the controller writes it, or a Regexp, optional
  #   fields: for updates, every field the update sets must be one of these, optional
  #   params: the request must have one of these query params, optional
  ALLOWED = [].freeze

  Write = Struct.new(:test, :route, :collection, :command, :fields, :params, keyword_init: true) do
    def to_s
      "#{route}: #{command} #{collection}#{" (#{fields.join(', ')})" if fields&.any?}"
    end
  end

  LOCK = Mutex.new
  REPORT_ONLY = true

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
      return false unless entry[:collection] == write.collection
      return false if entry[:command] && entry[:command] != write.command
      return false if entry[:route] && !(entry[:route] === write.route)
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

    def report(env, test, writes)
      route = env[ROUTE_KEY] || "#{env['REQUEST_METHOD']} #{env['PATH_INFO']} (no route)"
      params = Rack::Utils.parse_query(env['QUERY_STRING'].to_s).keys
      writes.each do |write|
        GetWrites.record(Write.new(test: test, route: route, params: params, **write))
      end
    end
  end

  ROUTE_KEY = 'get_writes.route'.freeze
end

Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, GetWrites)
Padrino.use GetWrites::Middleware

# The route handling the request, as route recording names it. Each route tried sets it, so the last is the one that ran
Dandelion::App.before do
  route = request.route_obj
  next Padrino::Filter::SKIPPED unless route

  request.env[GetWrites::ROUTE_KEY] = RouteRecording.route_name(route)
  Padrino::Filter::SKIPPED
end
