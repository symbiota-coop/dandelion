# Line coverage of the app's Ruby and templates, when COVERAGE is set (as CI's Run workflow can): an HTML report in coverage/ and
# its results in coverage/.resultset.json. Runs at the same time merge their results there, each under its own name,
# so running a file again replaces its last results rather than adding to them. CI's coverage job collates its groups'
# with `rake test:coverage`. test/test_config.rb requires this first, as SimpleCov only sees files loaded after it starts
module TestCoverage
  VIEWS = 'app/views/**/*.erb'.freeze

  # SimpleCov runs a configuration block on itself
  CONFIG = proc do
    cover '{app,models,lib}/**/*.rb', VIEWS
    cover_views VIEWS # measures templates as they're rendered (eval coverage)
    group 'Controllers', 'app/controllers'
    group 'Helpers', 'app/helpers'
    group 'Views', 'app/views'
    group 'Models', 'models'
    group 'Lib', 'lib'
  end

  # SimpleCov adds the templates no test rendered at 0% for Rails' ActionView only, so Padrino's are compiled here,
  # without running them, so they count as uncovered rather than being left out
  def self.compile_unrendered_templates
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
