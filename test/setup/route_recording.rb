# Which routes each test requests. Every run records them, so a test that says it covers a route (covers_route) fails
# when it never requested it (TestHelpers#check_covered_routes_were_requested), as a mark is only true if the test
# reaches the route. RECORD_ROUTES=1 also writes them to tmp/routes/<pid>.json, for finding the tests that cover a route;
# CI's Run workflow does it with record routes ticked, as the routes artifact
module RouteRecording
  REQUESTS = Hash.new { |hash, test| hash[test] = Set.new }
  # Browser tests' requests arrive on Puma's threads
  LOCK = Mutex.new

  class << self
    attr_reader :requested

    # A fresh set for each attempt at a test, so a retry counts only its own requests
    def start(test)
      LOCK.synchronize do
        @test = test
        @requested = Set.new
      end
    end

    def record(route)
      LOCK.synchronize do
        next unless @test

        @requested << route
        REQUESTS[@test] << route if ENV['RECORD_ROUTES'].present?
      end
    end
  end
end

# As each route is tried, before the app's own before filters can halt it. Padrino runs a before filter once a request
# unless it returns SKIPPED, so a route tried after another passed (/accounts/providers/confirm after
# /accounts/:id/*) would go unrecorded. The routes that passed are recorded too, which can only add to what a test
# requested, never fail a mark
Dandelion::App.before do
  route = request.route_obj
  next Padrino::Filter::SKIPPED unless route

  # Padrino adds (.:format)? to the path the controller wrote, and keeps / as ''. HEAD is the GET route's
  path = route.original_path.delete_suffix('(.:format)?')
  path = '/' if path == ''
  RouteRecording.record("#{route.verb.sub('HEAD', 'GET')} #{path}")
  Padrino::Filter::SKIPPED
end

if ENV['RECORD_ROUTES'].present? # CI sets it empty unless asked for
  Minitest.after_run do
    FileUtils.mkdir_p('tmp/routes')
    File.write("tmp/routes/#{Process.pid}.json", RouteRecording::REQUESTS.transform_values(&:to_a).to_json)
  end
end
