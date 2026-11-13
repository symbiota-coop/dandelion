# The app's routes, read from app/app.rb and app/controllers without booting the app, and the routes tests say they
# cover with covers_route 'VERB /path' (AGENTS.md, Tests). test/lint_test.rb fails on a route no test covers, unless
# test/routes_without_tests.yml says why, and on a covers_route naming no route
module RouteMarks
  ROOT = File.expand_path('..', __dir__)
  # get '/path' or, in a named controller, get :name, map: '/path'
  DEFINITION = %r{\A\s*(?<verb>get|post|put|patch|delete)\s+(?:(?<q>['"])(?<path>/[^'"]*)\k<q>|:\w+,\s*map:\s*(?<mq>['"])(?<map>/[^'"]*)\k<mq>)}
  # A route for several verbs: %w[get post].each do |verb| ... send(verb, '/path') do
  VERBS = /\A\s*%[wi]\[(?<verbs>[a-z ]+)\]\.each do \|\w+\|/
  SENT = %r{\A\s*send\(\w+, (?<q>['"])(?<path>/[^'"]*)\k<q>\)}
  MARK = /\A\s*covers_route ('.+)/

  # 'VERB /path' => where it's defined, as file:line
  def self.routes
    [File.join(ROOT, 'app/app.rb'), *Dir[File.join(ROOT, 'app/controllers/*.rb')]].each_with_object({}) do |file, routes|
      at = ->(number) { "#{file.delete_prefix("#{ROOT}/")}:#{number}" }
      verbs = nil
      File.foreach(file, encoding: 'UTF-8').with_index(1) do |line, number|
        if (match = line.match(DEFINITION))
          routes["#{match[:verb].upcase} #{match[:path] || match[:map]}"] ||= at.call(number)
        elsif (match = line.match(VERBS))
          verbs = match[:verbs].split
        elsif verbs && (match = line.match(SENT))
          verbs.each { |verb| routes["#{verb.upcase} #{match[:path]}"] ||= at.call(number) }
          verbs = nil
        end
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
