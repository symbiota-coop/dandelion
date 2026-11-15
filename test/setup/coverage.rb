# Line and branch coverage of the app's Ruby and templates, when COVERAGE is set (as CI's Run workflow can): an HTML report in coverage/ and
# its results in coverage/.resultset.json. Runs at the same time merge their results there, each under its own name,
# so running a file again replaces its last results rather than adding to them. CI's coverage job collates its groups'
# with `rake test:coverage`. test/test_config.rb requires this first, as SimpleCov only sees files loaded after it starts
require 'cgi'

module TestCoverage
  VIEWS = 'app/views/**/*.erb'.freeze

  # SimpleCov runs a configuration block on itself
  CONFIG = proc do
    # Branches too: a line runs whichever way its condition goes, so line coverage can't tell a guard (`return false
    # unless organisation`, `|| admin?`) that only ever went one way in tests
    enable_coverage :branch
    cover '{app,models,lib}/**/*.rb', VIEWS
    cover_views VIEWS # measures templates as they're rendered (eval coverage)
    group 'Controllers', 'app/controllers'
    group 'Helpers', 'app/helpers'
    group 'Views', 'app/views'
    group 'Models', 'models'
    group 'Lib', 'lib'
  end

  # What a line that refuses something looks like. Most untaken branches are nil guards and view toggles, but one of
  # these is a rule (who may do what, what's invalid) that no test has seen refuse, so nothing would catch it being
  # dropped or inverted: a halt with a 4xx, kick!, not_found, a raise, a validation error or a *_required!/*_only! guard
  REFUSALS = [
    /\bhalt[\s(]+4\d\d\b/,
    /\bkick!/,
    /\bnot_found\b/,
    /\braise\s/,
    /\berrors\.add\b/,
    /\b\w+_(?:required|only)!/
  ].freeze
  # The MCP server and AI clients: what they refuse is a malformed call from an AI client, not a person
  REFUSALS_SKIPPED = %r{\Alib/ai/}
  REFUSALS_LISTED = 100

  Refusal = Struct.new(:file, :line, :source)

  # The refusals in the then side of each branch no test took (the body of an if, unless or ternary, or the line of a
  # modifier one), by file and line. Every line of an untaken branch is untaken, so all those matching in it count.
  # From Coverage's own data, as SimpleCov's branches don't say what made them: a safe navigation (`x&.y`) is a branch
  # too, and the halt in `halt 403 unless x&.y` can run while its `&.` has never called y
  def self.untaken_refusals(files)
    files.flat_map do |file|
      path = file.project_filename.delete_prefix('/')
      next [] if path.match?(REFUSALS_SKIPPED)

      source = file.src
      untaken_then_lines(file.coverage_data['branches'] || {}).flat_map do |lines|
        lines.filter_map do |number|
          line = source[number - 1].to_s.strip
          Refusal.new(path, number, line) if refusal?(line)
        end
      end
    end.uniq.sort_by { |refusal| [refusal.file, refusal.line] }
  end

  # Coverage gives each branch as [type, id, start_line, start_column, end_line, end_column], or that as a string once
  # it's been through .resultset.json
  def self.untaken_then_lines(conditions)
    parse = SimpleCov::SourceFile::RubyDataParser.method(:call)
    conditions.flat_map do |condition, branches|
      next [] if parse.call(condition).first == :'&.'

      branches.filter_map do |branch, count|
        type, _id, start_line, _start_column, end_line = parse.call(branch)
        (start_line..end_line) if type == :then && count.zero?
      end
    end
  end

  def self.refusal?(line)
    !line.start_with?('#', '<%#') && REFUSALS.any? { |pattern| line.match?(pattern) }
  end

  # The job summary's table of them, the first `limit`. Sources go in <code> with | escaped, as a code span
  # would end at a backtick in the source and a | would split the cell
  def self.untaken_refusals_summary(files, limit: REFUSALS_LISTED)
    refusals = untaken_refusals(files)
    rows = refusals.first(limit).map do |refusal|
      "| #{refusal.file}:#{refusal.line} | <code>#{CGI.escapeHTML(refusal.source).gsub('|', '&#124;')}</code> |"
    end
    more = refusals.count - limit
    ["\n### Untaken refusals: #{refusals.count}\n",
     'Refusals (`TestCoverage::REFUSALS`) in branches no test took, so no test sees them refuse:',
     '', '| Line | Source |', '|---|---|', *rows, *("\n…and #{more} more" if more.positive?)]
  end

  # SimpleCov adds the templates no test rendered at 0% for Rails' ActionView only, so Padrino's are compiled here,
  # without running them, so they count as uncovered rather than being left out. Not once Coverage has stopped: when
  # a run at the same time has already reported (as test:parallel's runs do), SimpleCov collects this run's result
  # before its exit task, to check it isn't empty, and that run's results already list the unrendered templates
  def self.compile_unrendered_templates
    return unless Coverage.running?

    rendered = Coverage.peek_result.keys.to_set
    Dir[File.expand_path("../#{VIEWS}", __dir__)].each do |path|
      next if rendered.include?(path)

      Tilt.new(path).compiled_method([], Object)
    rescue StandardError, SyntaxError => e
      warn "#{path} didn't compile for coverage (#{e.class})"
    end
  end
end

if ENV['COVERAGE'].to_s != '' # CI sets it empty unless coverage was asked for
  require 'simplecov'
  SimpleCov.start do
    instance_exec(&TestCoverage::CONFIG)
    # rake test:files runs every file in TEST_FILES through Rake's loader, so $PROGRAM_NAME wouldn't tell runs apart
    command_name ENV['TEST_FILES'] || $PROGRAM_NAME
    # SimpleCov's own exit task, after the templates no test rendered
    at_exit do
      TestCoverage.compile_unrendered_templates
      result = SimpleCov.result
      result.format! if result && SimpleCov.merge_finalization_owner?
    end
  end
end
