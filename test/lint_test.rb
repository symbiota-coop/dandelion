# Tests our own checks (AGENTS.md, Custom checks): the Dandelion cops, the erb_lint linters, the ESLint and Stylelint
# rules, and script/lint. It doesn't boot the app, so it runs without foreman or Mongo:
#
#   bundle exec ruby -I test test/lint_test.rb
#
# The ESLint and Stylelint tests need node_modules (npm ci), and skip without it; CI's lint job runs them.
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'rubocop'
require 'erb_lint/all'

class LintTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  RUBOCOP_CONFIG = RuboCop::ConfigStore.new.for_file(File.join(ROOT, 'app/x.rb'))
  DANDELION_COPS = RuboCop::Cop::Registry.global.select { |cop| cop.department == :Dandelion }
  BOOTSTRAP_4 = JSON.parse(File.read(File.join(ROOT, 'config/bootstrap4_leftovers.json'), encoding: 'UTF-8'))

  # A file a cop checks: one in its Include, if it has one (Dandelion/RailsController only checks controllers)
  def cop_path(cop)
    (RUBOCOP_CONFIG.for_cop(cop)['Include']&.first || 'app/**/*.rb').sub('**/*', 'x')
  end

  # The offenses one cop finds in some Ruby, in a file it checks
  def cop_offenses(cop, code, path = cop_path(cop))
    source = RuboCop::ProcessedSource.new(code, RUBOCOP_CONFIG.target_ruby_version, File.join(ROOT, path))
    source.config = RUBOCOP_CONFIG
    source.registry = RuboCop::Cop::Registry.global
    RuboCop::Cop::Team.mobilize([cop], RUBOCOP_CONFIG, raise_error: true).investigate(source).offenses
  end

  # The bad and good code in a cop's @example, as its comment shows them
  def cop_examples(cop)
    path = File.join(ROOT, '.rubocop/dandelion', "#{cop.cop_name.delete_prefix('Dandelion/').gsub(/(?<!^)([A-Z])/, '_\1').downcase}.rb")
    comment = File.read(path)[/# @example\n((?:\s*#.*\n)+?)\s*class /, 1]
    lines = comment.lines.map { |line| line.sub(/\A\s*#\s?/, '').delete_prefix('  ') }
    sections = lines.slice_before { |line| line.match?(/\A# (bad|good)$/) }.to_h { |section| [section.first[/bad|good/], section.drop(1).join] }
    [sections.fetch('bad'), sections.fetch('good')]
  end

  # Each top-level statement in some Ruby
  def statements(code)
    ast = RuboCop::ProcessedSource.new(code, RUBOCOP_CONFIG.target_ruby_version).ast
    ast.begin_type? ? ast.children : [ast]
  end

  def test_each_cop_flags_each_bad_example_and_no_good_one
    DANDELION_COPS.each do |cop|
      bad, good = cop_examples(cop)
      flagged = cop_offenses(cop, bad).map(&:line).uniq
      statements(bad).each do |statement|
        assert flagged.any? { |line| statement.source_range.line_span.include?(line) }, "#{cop.cop_name} misses its bad example: #{statement.source}"
      end
      assert_empty cop_offenses(cop, good).map(&:message), "#{cop.cop_name} flags its good example"
    end
  end

  def test_cop_edge_cases
    {
      'Dandelion/ParamsBlank' => { 'params[:a][:b].present?' => 1, 'params.fetch(:a).present?' => 0, 'foo.dig(:a).present?' => 0, 'x.blank?' => 0 },
      'Dandelion/CapybaraRefuteHas' => {
        'refute has_css?(".x")' => 1, 'assert_equal false, page.has_sibling?("x")' => 1, 'assert_equal true, page.has_css?(".x")' => 0,
        'assert page.has_css?(".x")' => 0, 'refute page.has_no_css?(".x")' => 0, 'refute foo.valid?' => 0
      },
      'Dandelion/MongoidWhere' => { "where('this.a < this.b')" => 0, 'where(a: 1)' => 1, 'x&.where(a: 1)' => 1 },
      'Dandelion/MongoidOr' => { 'x.or(a: 1)' => 1, 'a or b' => 0 },
      'Dandelion/ErrorReporting' => { 'Sentry.capture_message("x")' => 1, '::Sentry.capture_exception(e)' => 1, 'ErrorReporting.capture_exception(e)' => 0 },
      'Dandelion/ValidateBlock' => { 'validate :name_is_short' => 0, 'validate { errors.add(:name, "x") }' => 1 },
      'Dandelion/RailsController' => {
        'params[:event].permit(:name)' => 1, 'skip_before_action :x' => 1, 'pdf.render' => 0, 'EmailHelper.render(:x)' => 0,
        'require "x"' => 0, 'x.respond_to?(:y)' => 0, 'event.permit(:x)' => 0
      }
    }.each do |name, cases|
      cop = RuboCop::Cop::Registry.global.find_by_cop_name(name)
      cases.each { |code, count| assert_equal count, cop_offenses(cop, code).size, "#{name} on #{code}" }
    end
  end

  def test_rails_controller_only_checks_controllers
    cop = RuboCop::Cop::Registry.global.find_by_cop_name('Dandelion/RailsController')
    assert_empty cop_offenses(cop, 'render :show', 'app/helpers/x.rb')
  end

  def test_agents_md_lists_each_cop
    listed = File.read(File.join(ROOT, 'AGENTS.md'), encoding: 'UTF-8').scan(/^- `(Dandelion\/\w+)`/).flatten
    assert_equal DANDELION_COPS.map(&:cop_name).sort, listed.sort
  end

  # The offenses erb_lint (with .erb_lint.yml) finds in a template, as [linter, message]
  def erb_offenses(source)
    loader = ERBLint::FileLoader.new(ROOT)
    ERBLint::LinterRegistry.load_custom_linters(File.join(ROOT, '.erb_linters'))
    runner = ERBLint::Runner.new(loader, ERBLint::RunnerConfig.new(loader.yaml(File.join(ROOT, '.erb_lint.yml')), loader))
    runner.run(ERBLint::ProcessedSource.new(File.join(ROOT, 'app/views/x.erb'), source))
    runner.offenses.map { |offense| [offense.linter.class.simple_name, offense.message] }
  end

  def test_design_classes
    {
      '<div class="badge text-bg-success">' => /-success/,
      '<span class="badge badge-danger">' => /badge-\*/,
      '<span class="label">' => /\.label/,
      %(<a onclick="$('#x').addClass('d-none')">) => /d-none/,
      '<div class="ml-2">' => /ms-\*/,
      %(<%= link_to 'x', '#', class: 'float-right' %>) => /float-start/,
      '<button class="close">' => /btn-close/,
      %(<script>$('#x').removeClass('text-left')</script>) => /text-start/,
      '<a data-toggle="tooltip">' => /data-bs-\*/,
      %(<%= link_to 'x', '#', data: { toggle: 'dropdown' } %>) => /data-bs-\*/
    }.each do |template, message|
      offenses = erb_offenses(template).select { |linter, _| linter == 'DesignClasses' }
      assert_equal 1, offenses.size, "DesignClasses on #{template}: #{offenses.inspect}"
      assert_match message, offenses.first.last
    end

    [
      '<div class="ms-2 me-auto text-end float-start rounded-1 btn-close closed html-label media form-group form-inline">',
      '<div data-bs-toggle="tooltip" data-parent="x" data-target="y">',
      %(<div class="<%= 'ml-2' %>">), # Ruby inside the attribute isn't a class
      '<p>Close it, then align it left</p>'
    ].each { |template| assert_empty erb_offenses(template), template }
  end

  def test_rubocop_tags_checks_conditions
    {
      '<% if params[:q].present? %>x<% end %>' => ['Dandelion/ParamsBlank'],
      '<% unless x.presence %>x<% end %>' => ['Dandelion/Presence'],
      '<% if a %>x<% elsif Event.live.or(b: 1).exists? %>y<% end %>' => ['Dandelion/MongoidOr'],
      '<% if (x = y) %>x<% end %>' => [],
      '<% if a %>x<% else %>y<% end %>' => [],
      %(<% if a %>\n  <% if b %>x<% end %>\n<% end %>) => [],
      '<% x = 1 if y %>' => [],
      '<% events.where(a: 1).each do |e| %><%= e %><% end %>' => ['Dandelion/MongoidWhere']
    }.each do |template, cops|
      flagged = erb_offenses(template).select { |linter, _| linter == 'RubocopTags' }.map { |_, message| message[/\A[\w\/]+/] }
      assert_equal cops, flagged, template
    end
  end

  # Bootstrap 5 and our stylesheets define these, so the Bootstrap 4 list mustn't flag them
  def test_bootstrap_4_list_flags_no_current_class
    css = Dir[File.join(ROOT, 'app/assets/stylesheets/*.css')].map { |f| File.read(f, encoding: 'UTF-8') }.join
    classes = css.scan(/\.(-?[a-z][\w-]*)/i).flatten.uniq
    BOOTSTRAP_4['classes'].each do |entry|
      pattern = /\A(?:#{entry['pattern']})\z/
      assert_empty classes.grep(pattern), "#{entry['pattern']} matches classes we have"
    end
  end

  def node_modules!
    skip 'needs node_modules (npm ci)' unless File.directory?(File.join(ROOT, 'node_modules'))
  end

  # A linter's JSON report on some source, piped in. Stylelint writes it to stderr when it finds something
  def node_lint(command, source)
    stdout, stderr, = Open3.capture3(*command, stdin_data: source, chdir: ROOT)
    JSON.parse(stdout.empty? ? stderr : stdout)
  end

  def eslint_rules(source)
    result = node_lint(%w[npx eslint --format json --stdin --stdin-filename app/assets/javascripts/x.js], source)
    result.first['messages'].map { |message| message['message'] }
  end

  def test_eslint_rules
    node_modules!
    {
      %(/* global el */\nel.classList.add('d-none')) => /d-none/,
      %($('#x').html(`<span class="badge text-bg-success">${1}</span>`)) => /-success/,
      %($('#x').html('<span class="badge badge-info">')) => /badge-\*/,
      %($('#x').html('<span class="label">')) => /\.label/,
      %($('#x').addClass('mr-3')) => /ms-\*/,
      %($('#x').attr('data-toggle', 'tooltip')) => /data-bs-\*/
    }.each do |source, message|
      messages = eslint_rules(source)
      assert_equal 1, messages.size, "ESLint on #{source}: #{messages.inspect}"
      assert_match message, messages.first
    end
    assert_empty eslint_rules(%($('#x').html('<label class="form-label ms-2 media" data-bs-toggle="x">').addClass('text-end').removeClass('with-label'))),
                 'ESLint flags Bootstrap 5 and our own classes'
  end

  def stylelint_rules(source, path = 'app/assets/stylesheets/x.css')
    result = node_lint(['npx', 'stylelint', '--formatter', 'json', '--stdin-filename', path], source)
    result.first['warnings'].map { |warning| warning['rule'] }
  end

  def test_stylelint_rules
    node_modules!
    {
      '.a { color: #fff; }' => 'declaration-property-value-disallowed-list',
      '.a { color: rgba(0, 0, 0, 0.5); }' => 'declaration-property-value-disallowed-list',
      '.a { color: white; }' => 'color-named',
      '.a { border-radius: 7px; }' => 'declaration-property-value-disallowed-list',
      '.a { box-shadow: 0 2px 9px var(--x); }' => 'declaration-property-value-disallowed-list',
      '.a { margin-left: 4px; }' => 'declaration-property-unit-disallowed-list',
      '.a { top: 12px; }' => 'declaration-property-unit-disallowed-list'
    }.each { |source, rule| assert_equal [rule], stylelint_rules(source), source }

    good = <<~CSS
      .a { --c: #fff; color: rgba(var(--bs-black-rgb), 0.5); background: transparent; border: 1px solid var(--hairline); }
      .b { border-radius: 0 0 var(--bs-border-radius) 50%; box-shadow: inset 0 0 0 1px var(--x), var(--bs-box-shadow); margin: var(--space-xs) 0.375rem; }
    CSS
    assert_empty stylelint_rules(good)
    assert_equal ['declaration-property-value-disallowed-list'], stylelint_rules('.a { color: var(--x); }', 'app/assets/stylesheets/email.css')
  end

  def lint(*args)
    Open3.capture2e(File.join(ROOT, 'script/lint'), *args, chdir: ROOT)
  end

  def test_script_lint_usage
    [[], %w[--staged x.rb], %w[--all --only nonsense], %w[--only]].each do |args|
      output, status = lint(*args)
      refute status.success?, args.inspect
      assert_match(/Usage/, output)
    end
  end

  def test_script_lint_runs_each_linter_on_its_files
    node_modules!
    files = %w[script/lint app/views/design.erb app/assets/javascripts/utils.js app/assets/stylesheets/docs.css]
    output, status = lint(*files)
    assert status.success?, output
    assert_match(/Passed: RuboCop, erb_lint, ESLint, Stylelint/, output)
  end

  def test_script_lint_fails_on_an_offense
    Dir.mktmpdir do |dir|
      bad = File.join(dir, 'bad.rb')
      File.write(bad, "def x\n  y = 1\nend\n") # Lint/UselessAssignment, a warning
      output, status = lint(bad, 'script/lint')
      refute status.success?, output
      assert_match(/Failed: RuboCop/, output)
    end
  end
end
