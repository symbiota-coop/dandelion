# RECORD_ROUTES=1 records which routes each test requests, in tmp/routes/<pid>.json, for finding the tests that cover
# a route (covers_route). CI's Run workflow does it with record routes ticked, as the routes artifact
module RouteRecording
  REQUESTS = Hash.new { |hash, test| hash[test] = Set.new }

  class << self
    attr_accessor :test
  end
end

if ENV['RECORD_ROUTES'].present? # CI sets it empty unless asked for
  # As the route is matched, before the app's own before filters can halt it
  Dandelion::App.before do
    route = request.route_obj
    # Padrino adds (.:format)? to the path the controller wrote, and keeps / as ''. HEAD is the GET route's
    path = route.original_path.delete_suffix('(.:format)?') if route
    path = '/' if path == ''
    RouteRecording::REQUESTS[RouteRecording.test] << "#{route.verb.sub('HEAD', 'GET')} #{path}" if route && RouteRecording.test
  end
  Minitest.after_run do
    FileUtils.mkdir_p('tmp/routes')
    File.write("tmp/routes/#{Process.pid}.json", RouteRecording::REQUESTS.transform_values(&:to_a).to_json)
  end
end
