# The app's routes, read from app/app.rb and app/controllers without booting the app, and the routes tests say they cover with
# covers_route 'VERB /path' (AGENTS.md, Tests). test/lint_test.rb fails on a route no test covers, unless
# test/routes_without_tests.yml says why, and on a covers_route naming no route
module RouteMarks
  ROOT = File.expand_path('..', __dir__)
  # get '/path' or, in a named controller, get :name, map: '/path'
  DEFINITION = %r{\A\s*(?<verb>get|post|put|patch|delete)\s+(?:(?<q>['"])(?<path>/[^'"]*)\k<q>|:\w+,\s*map:\s*(?<mq>['"])(?<map>/[^'"]*)\k<mq>)}
  MARK = /\A\s*covers_route ('.+)/

  # 'VERB /path' => where it's defined, as file:line
  def self.routes
    [File.join(ROOT, 'app/app.rb'), *Dir[File.join(ROOT, 'app/controllers/*.rb')]].each_with_object({}) do |file, routes|
      File.foreach(file, encoding: 'UTF-8').with_index(1) do |line, number|
        next unless (match = line.match(DEFINITION))

        routes["#{match[:verb].upcase} #{match[:path] || match[:map]}"] ||= "#{file.delete_prefix("#{ROOT}/")}:#{number}"
      end
    end
  end

  # ['VERB /path', file:line] for each covers_route in the tests
  def self.marks
    Dir[File.join(ROOT, 'test/**/*_test.rb')].flat_map do |file|
      File.readlines(file, encoding: 'UTF-8').each_with_index.flat_map do |line, index|
        line[MARK, 1].to_s.scan(/'([^']*)'/).flatten.map { |route| [route, "#{file.delete_prefix("#{ROOT}/")}:#{index + 1}"] }
      end
    end
  end
end
