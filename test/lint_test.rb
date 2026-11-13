# Tests our own checks (AGENTS.md, Linting): the Dandelion cops, the erb_lint linters, the ESLint, Stylelint and
# Herb rules, and script/lint. It doesn't boot the app, so it runs without foreman or Mongo:
#
#   bundle exec ruby -I test test/lint_test.rb
#
# The ESLint, Stylelint and Herb tests need them installed (npm ci), and skip without them; CI's lint job runs them.
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rake'
require 'tmpdir'
require 'yaml'
require 'rubocop'
require 'erb_lint/all'
require_relative '../lib/doc_claims'
require_relative '../lib/route_marks'

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
    lines = comment.lines.map { |line| line.sub(/\A\s*# ?/, '').delete_prefix('  ') }
    sections = lines.slice_before { |line| line.match?(/\A# (bad|good)$/) }.to_h { |section| [section.first[/bad|good/], section.drop(1).join] }
    [sections.fetch('bad'), sections.fetch('good')]
  end

  # The cases in a cop's bad example: each top-level statement, or, where blank lines split it into paragraphs (for a cop
  # about a sequence of statements), each paragraph. Each as its [first line, last line]
  def bad_cases(code)
    if code.strip.include?("\n\n")
      code.lines.each_with_index.chunk_while { |(line, _), _| line.strip != '' }.filter_map do |chunk|
        lines = chunk.reject { |line, _| line.strip.empty? }.map { |_, index| index + 1 }
        [lines.first, lines.last] if lines.any?
      end
    else
      ast = RuboCop::ProcessedSource.new(code, RUBOCOP_CONFIG.target_ruby_version).ast
      (ast.begin_type? ? ast.children : [ast]).map { |statement| [statement.first_line, statement.last_line] }
    end
  end

  def test_each_cop_flags_each_bad_example_and_no_good_one
    DANDELION_COPS.each do |cop|
      bad, good = cop_examples(cop)
      flagged = cop_offenses(cop, bad).map(&:line).uniq
      bad_cases(bad).each do |first, last|
        assert flagged.any? { |line| (first..last).cover?(line) }, "#{cop.cop_name} misses its bad example: #{bad.lines[(first - 1)..(last - 1)].join.strip}"
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
      'Dandelion/MongoidWhere' => { "where('this.a < this.b')" => 1, 'where(a: 1)' => 1, 'x&.where(a: 1)' => 1 },
      'Dandelion/MongoidOr' => { 'x.or(a: 1)' => 1, 'a or b' => 0 },
      'Dandelion/ErrorReporting' => { 'Sentry.capture_message("x")' => 1, '::Sentry.capture_exception(e)' => 1, 'ErrorReporting.capture_exception(e)' => 0 },
      'Dandelion/ValidateBlock' => { 'validate :name_is_short' => 0, 'validate { errors.add(:name, "x") }' => 1 },
      'Dandelion/CapybaraHasNoAfterClick' => {
        "click_link 'x'\nassert has_no_link?('x')" => 1, "find('.x').click\nassert_no_selector('.y')" => 1,
        "accept_confirm { click_button 'x' }\nassert page.has_no_css?('.y')" => 1, "click_button 'x'\nvisit '/'\nassert page.has_no_css?('.y')" => 0,
        "dismiss_prompt { click_on 'x' }\nassert page.has_no_css?('.y')" => 0, "fill_in 'x', with: 'y'\nassert page.has_no_css?('.y')" => 0
      },
      'Dandelion/CapybaraCurrentPath' => {
        'assert_equal "/x", page.current_path' => 1, 'x = current_url' => 1, %(assert page.has_current_path?("/x"), "Got \#{page.current_path}") => 0,
        'session.current_path' => 0
      },
      'Dandelion/TestInstanceVariable' => {
        "test 'x' do\n  @a ||= 1\nend" => 1, "it 'x' do\n  @a = 1\nend" => 0, "def setup_a\n  @a = 1\nend\ntest 'x' do\n  @a = 2\nend" => 0
      },
      'Dandelion/ConcernInclude' => {
        "included do\n  include Searchable, Taggable\nend" => 2, "included do\n  include ::Searchable\nend" => 0, 'include Searchable' => 0,
        "included do\n  include Mongoid::Document\nend" => 0, "class_methods do\n  include Searchable\nend" => 0, "x.included do\n  include Searchable\nend" => 0
      },
      'Dandelion/MongoidIndex' => { 'index slug: 1' => 1, 'index' => 0, 'events.index(1)' => 0 },
      'Dandelion/MailgunDirect' => {
        'Mailgun::Client.new(key, region)' => 1, '::Mailgun::BatchMessage.new(client, host)' => 1, 'Mailgun::Tags.new(client)' => 0,
        'Mailgun::BatchMessage.stub(:new, email) { x }' => 0, 'Mailer.deliver(:csv, to: account, subject: "x")' => 0
      },
      'Dandelion/Redcarpet' => { '::Redcarpet::Render::HTML.new' => 1, 'Redcarpet' => 1, 'Foo::Redcarpet' => 0, 'MarkdownRenderer.render(x)' => 0 },
      'Dandelion/SlugLookup' => {
        'Gathering.find_by(slug: params[:gathering_slug], x: 1)' => 1, 'Event&.find(params[:event_slug])' => 1, 'Event.find(params[:event_id])' => 0,
        'organisation.activities.find(params[:id])' => 0, 'Order.find(params[:id])' => 0, 'Event.find(id)' => 0, 'Event.find_by(slug: slug)' => 0,
        'Organisation.find_by_slug_or_id(slug: params[:organisation_slug]) || not_found' => 1, 'Account.find_by_slug_or_id(slug: params[:username]) || not_found' => 1,
        'Organisation.find_by_slug_or_id(slug: params[:slug])' => 0, 'Event.find_by_slug_or_id(slug: params[:cohost]) || not_found' => 0,
        'activity_from_params || not_found' => 1, 'x || not_found' => 0
      },
      'Dandelion/GatheringScope' => {
        'Shift.find(params[:id])' => 1, 'Membership&.find(params[:membership][:id])' => 1, 'Team.find_by(id: params[:team_id], x: 1)' => 1,
        '@gathering.shifts.find(params[:id])' => 0, 'Shift.find(id)' => 0, 'Event.find(params[:id])' => 0, 'Gathering.find_by_slug_or_id(slug: params[:slug])' => 0
      },
      'Dandelion/GatheringPermission' => {
        "get '/g/:slug/x' do\n  erb :x\nend" => 1, "post '/g/:slug/x' do\nend" => 1, "post '/g/:slug/x' do\n  halt unless y\n  z\nend" => 1,
        "post '/g/:slug/x' do\n  halt 403 unless y\n  z\nend" => 0, "get '/g/:slug/x' do\n  membership_required!\n  erb :x\nend" => 0,
        "get '/events/:slug' do\n  erb :x\nend" => 0, "get '/g/new' do\n  erb :x\nend" => 0
      },
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

  def test_gathering_permission_only_checks_controllers
    cop = RuboCop::Cop::Registry.global.find_by_cop_name('Dandelion/GatheringPermission')
    assert_empty cop_offenses(cop, "get '/g/:slug/x' do\n  erb :x\nend", 'lib/x.rb')
  end

  def test_slug_lookup_only_checks_controllers
    cop = RuboCop::Cop::Registry.global.find_by_cop_name('Dandelion/SlugLookup')
    assert_empty cop_offenses(cop, 'Event.find(params[:id])', 'lib/x.rb')
  end

  def test_gathering_scope_only_checks_controllers
    cop = RuboCop::Cop::Registry.global.find_by_cop_name('Dandelion/GatheringScope')
    assert_empty cop_offenses(cop, 'Shift.find(params[:id])', 'lib/x.rb')
  end

  # Dandelion/GatheringScope lists the models to find through their gathering by hand, so a new model that belongs to a
  # gathering is added there, or a route could find another gathering's by id
  def test_gathering_scope_lists_every_model_that_belongs_to_a_gathering
    models = Dir[File.join(ROOT, 'models/*.rb')].select { |path| File.read(path, encoding: 'UTF-8').match?(/^\s*belongs_to\w* :gathering\b/) }
    names = models.map { |path| File.basename(path, '.rb').split('_').map(&:capitalize).join }
    assert_equal names.sort, RuboCop::Cop::Dandelion::GatheringScope::MODELS.sort,
                 'MODELS in .rubocop/dandelion/gathering_scope.rb should be the models that belong to a gathering'
  end

  def test_mailgun_is_used_directly_only_in_lib_mail
    cop = RuboCop::Cop::Registry.global.find_by_cop_name('Dandelion/MailgunDirect')
    assert_empty cop_offenses(cop, 'Mailgun::Client.new(key, region)', 'lib/mail/mailer.rb')
    assert_equal 1, cop_offenses(cop, 'Mailgun::Client.new(key, region)', 'models/x.rb').size
  end

  def test_redcarpet_is_allowed_only_in_markdown_renderer
    cop = RuboCop::Cop::Registry.global.find_by_cop_name('Dandelion/Redcarpet')
    assert_empty cop_offenses(cop, 'Redcarpet::Markdown.new(x)', 'lib/markdown_renderer.rb')
    assert_equal 1, cop_offenses(cop, 'Redcarpet::Markdown.new(x)', 'lib/x.rb').size
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
      %(<%= link_to 'x', '#', onclick: "$('#x').addClass('d-none')" %>) => /d-none/,
      '<div class="ml-2">' => /ms-\*/,
      %(<%= link_to 'x', '#', class: 'float-right' %>) => /float-start/,
      '<button class="close">' => /btn-close/,
      %(<%= button_tag 'x', onclick: "$(this).removeClass('text-left')" %>) => /text-start/,
      '<a data-toggle="tooltip">' => /data-bs-\*/,
      %(<%= link_to 'x', '#', data: { toggle: 'dropdown' } %>) => /data-bs-\*/,
      '<select name="x" class="me-1">' => /form-select/,
      "<%= select_tag :x,\n  class: 'me-1', options: [] %>" => /form-select/,
      '<a class="btn btn-sm btn-outline-primary show mb-1">' => /open-dropdown/
    }.each do |template, message|
      offenses = erb_offenses(template).select { |linter, _| linter == 'DesignClasses' }
      assert_equal 1, offenses.size, "DesignClasses on #{template}: #{offenses.inspect}"
      assert_match message, offenses.first.last
    end

    [
      '<div class="ms-2 me-auto text-end float-start rounded-1 btn-close closed html-label media form-group form-inline">',
      '<div data-bs-toggle="tooltip" data-parent="x" data-target="y">',
      %(<div class="<%= 'ml-2' %>">), # Ruby inside the attribute isn't a class
      '<p>Close it, then align it left</p>',
      %(<select class="form-select form-select-sm" data-x="a>b">), %(<%= select_tag :x, options: [1, 2],\n  class: 'form-select d-inline-block' %>),
      '<p>A select_tag needs one too</p>',
      '<div class="collapse show"><a class="btn form-toggle">', # .show is fine off a button, as on an open collapse
      # ESLint checks the template's own scripts and event attributes
      %(<script>$('#x').addClass('d-none')</script><a onclick="$(this).removeClass('text-left')">)
    ].each { |template| assert_empty erb_offenses(template), template }
  end

  def test_jquery_requests
    [%(<%= link_to 'x', '#', onclick: "fetch(this.href)" %>), %(<%= button_tag 'x',\n  onclick: 'fetch("/x")' %>)].each do |template|
      offenses = erb_offenses(template).select { |linter, _| linter == 'JqueryRequests' }
      assert_equal 1, offenses.size, "JqueryRequests on #{template}: #{offenses.inspect}"
    end
    # ESLint checks the template's own scripts and event attributes
    [%(<script>fetch('/x')</script><a onclick="fetch(this.href)">), %(<%= ENV.fetch('X', nil) %>), %(<%= link_to 'x', '#', onclick: 'x.fetch(1)' %>)].each do |template|
      assert_empty erb_offenses(template), template
    end
  end

  def test_post_links
    [
      %(<a href="/comments/<%= comment.id %>/destroy">Delete</a>),
      %(<a class="btn" href="/e/<%= @event.slug %>/destroy?no_refunds=1">Delete</a>),
      %(<a href="/event_feedbacks/1/hard_destroy" data-method="get">x</a>),
      %(<%= dropdown_nav [\n  ['Remove order', "/orders/\#{order.id}/destroy"]\n] %>),
      %(<%= dropdown_nav [(['Refund', "/orders/\#{id}/refund_and_destroy"] if x)] %>)
    ].each do |template|
      offenses = erb_offenses(template).select { |linter, _| linter == 'PostLinks' }
      assert_equal 1, offenses.size, "PostLinks on #{template}: #{offenses.inspect}"
    end

    [
      %(<a data-method="post" href="/comments/<%= comment.id %>/destroy">Delete</a>),
      %(<a href="/e/x/delete">Delete event</a><a href="/destroyers">x</a><a href="/x?then=destroy">x</a>),
      %(<a href="javascript:;" onclick="$.post('/drafts/1/destroy')">x</a>),
      %(<%= dropdown_nav [['Remove order', "/orders/\#{order.id}/destroy", { 'data-method' => 'post' }]] %>),
      %(<%= f.submit_block destroy_url: "/teams/\#{team.id}/destroy" %>)
    ].each { |template| assert_empty erb_offenses(template).select { |linter, _| linter == 'PostLinks' }, template }
  end

  # A gathering's pages, in these folders, all show its nav (gatherings/_nav.erb), so none feels cut off from the rest
  GATHERING_VIEW_DIRS = %w[gatherings rotas timetables teams options inventory budget mapplications].freeze
  # Pages for people outside the gathering, and a team's page, whose layout (layouts/teams.erb) shows the nav
  GATHERING_PAGES_WITHOUT_NAV = %w[gatherings/gatherings gatherings/join mapplications/apply teams/team].freeze

  def test_gathering_pages_show_the_gathering_nav
    missing = GATHERING_VIEW_DIRS.flat_map { |dir| Dir[File.join(ROOT, 'app/views', dir, '[!_]*.erb')] }.filter_map do |path|
      page = path.delete_prefix(File.join(ROOT, 'app/views/')).delete_suffix('.erb')
      page unless GATHERING_PAGES_WITHOUT_NAV.include?(page) || File.read(path, encoding: 'UTF-8').include?("partial :'gatherings/nav'")
    end
    assert_empty missing, "Gathering pages show the gathering nav: add <%= partial :'gatherings/nav', locals: { gathering: @gathering, membership: @membership } %> " \
                          'at the top, or list the page in GATHERING_PAGES_WITHOUT_NAV if it is for people outside the gathering'
  end

  # A gathering's subpages go back with gatherings/_back.erb, under their heading, so the links all look and sit the same
  def test_gathering_back_links_use_the_partial
    offenders = GATHERING_VIEW_DIRS.flat_map { |dir| Dir[File.join(ROOT, 'app/views', dir, '*.erb')] }.select do |path|
      File.read(path, encoding: 'UTF-8').match?(/>\s*(?:<i [^>]*><\/i>\s*)?Return to /) && !path.end_with?('gatherings/_back.erb')
    end
    assert_empty offenders.map { |path| path.delete_prefix("#{ROOT}/") },
                 "Gathering pages go back with <%= partial :'gatherings/back', locals: { to: 'rota', path: ... } %>, under their heading"
  end

  def test_icon_first
    [
      %(<a class="btn btn-primary" href="#">Star <i class="bi bi-star"></i></a>),
      %(<button class="btn btn-sm">\n  <%= label %>\n  <i class="bi bi-qr-code"></i>\n</button>)
    ].each do |template|
      offenses = erb_offenses(template).select { |linter, _| linter == 'IconFirst' }
      assert_equal 1, offenses.size, "IconFirst on #{template}: #{offenses.inspect}"
    end

    [
      %(<a class="btn btn-primary" href="#"><i class="bi bi-star"></i> Star</a>),
      %(<a class="btn" href="#"><i class="bi bi-pencil"></i></a>), # just an icon
      %(<button class="btn">Pay <i class="bi bi-spin bi-slash-lg" style="display: none"></i></button>), # a spinner while it waits
      %(<a class="text-primary" href="#">Info <i class="bi bi-info-circle"></i></a>), # not a button
      %(<a class="btn <%= 'active' if x %>" href="#"<% if y %> rel="nofollow"<% end %>><i class="bi bi-map"></i> Map</a>), # ERB in the tag
      %(<a class="btn" href="#"><% if heart %><i class="bi bi-heart-fill"></i><% else %><%= emoji %><% end %></a>) # logic isn't text
    ].each { |template| assert_empty erb_offenses(template).select { |linter, _| linter == 'IconFirst' }, template }
  end

  def test_money_fields
    [
      %(<%= f.number_block :cost %>), %(<%= f.number_block :amount, min: 0 %>), %(<%= f.number_block(:ticket_price) %>)
    ].each do |template|
      offenses = erb_offenses(template).select { |linter, _| linter == 'MoneyFields' }
      assert_equal 1, offenses.size, "MoneyFields on #{template}: #{offenses.inspect}"
    end

    [
      %(<%= f.currency_block :cost, money_symbol: money_symbol(@gathering.currency) %>),
      %(<%= f.number_block :capacity %>), %(<%= f.number_block :worth %>), %(<%= f.number_block :costume_count %>)
    ].each { |template| assert_empty erb_offenses(template).select { |linter, _| linter == 'MoneyFields' }, template }
  end

  def test_heading_container
    [
      %(<h2>Edit rota</h2>\n<div class="container">\n  <form></form>\n</div>),
      %(<h2><%= x ? 'Create' : 'Edit' %></h2>\n<%# the form %>\n<div class="container mt-3">)
    ].each do |template|
      offenses = erb_offenses(template).select { |linter, _| linter == 'HeadingContainer' }
      assert_equal 1, offenses.size, "HeadingContainer on #{template}: #{offenses.inspect}"
    end

    [
      %(<h2>Edit rota</h2>\n<form></form>),
      %(<%= partial :'accounts/nav' %>\n<div class="container">),
      %(<h2>Teams</h2>\n<div class="container-fluid">\n<div class="my-container">)
    ].each { |template| assert_empty erb_offenses(template).select { |linter, _| linter == 'HeadingContainer' }, template }
  end

  def test_cdn_tags
    {
      '<script src="https://cdn.jsdelivr.net/npm/x@1.0.0/x.min.js"></script>' => /cdn_tag/,
      %(<script defer src='https://unpkg.com/x@1.0.0/x.js'></script>) => /cdn_tag/,
      '<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/x@1.0.0/x.css">' => /cdn_tag/,
      %(<%= cdn_tag 'https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js' %>) => /Name the package and file/,
      %(<%= cdn_tag 'not-a-package', 'x.min.js' %>) => %r{isn't in frontend/package\.json},
      %(<%= cdn_tag('jquery', 'dist/jquery.js', defer: true) %>) => /rake frontend:integrity/,
      %(<%= cdn_tag 'https://cdn.jsdelivr.net/gh/x/y@abc/y.js' %>) => /rake frontend:integrity/
    }.each do |template, message|
      offenses = erb_offenses(template).select { |linter, _| linter == 'CdnTags' }
      assert_equal 1, offenses.size, "CdnTags on #{template}: #{offenses.inspect}"
      assert_match message, offenses.first.last
    end

    [
      %(<%= cdn_tag 'jquery', 'dist/jquery.min.js' %>), %(<%= cdn_tag package, f, defer: true %>),
      %(<%= cdn_tag 'https://cdn.jsdelivr.net/gh/tgdwyer/WebCola@aab7e61cd9580c4c89180cc0a30594e12743a242/WebCola/cola.min.js' %>),
      '<link rel="preconnect" href="https://cdn.jsdelivr.net">', '<script src="https://js.stripe.com/v3/" defer></script>'
    ].each { |template| assert_empty erb_offenses(template).select { |linter, _| linter == 'CdnTags' }, template }
  end

  # better_html found each script's content by ==, so a <script> the same as an earlier one went unchecked
  def test_safe_erb_checks_every_script
    {
      "<script>a()</script>\n<script>var x = <%= x %></script>" => /to_json/,
      "<script>a()</script>\n<script>\n<% if x %>a()<% end %>\n</script>" => /statement not allowed/
    }.each do |template, message|
      offenses = erb_offenses(template).select { |linter, _| linter == 'SafeErb' }
      assert_equal 1, offenses.size, "SafeErb on #{template}: #{offenses.inspect}"
      assert_match message, offenses.first.last
    end
    assert_empty erb_offenses("<script>a()</script>\n<script>var x = <%== x.to_json %></script>"), 'to_json in a second script'
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

  # AGENTS.md, Linting: disable a check only where its rule doesn't apply, and say why in the comment
  DISABLES = {
    /rubocop:(?:disable|todo)\s/ => /rubocop:(?:disable|todo) [\w\/, ]+ -- \S/,
    /eslint-disable(?:-next-line|-line)?\s/ => /eslint-disable(?:-next-line|-line)? [\w\/@, -]+ -- \S/,
    /stylelint-disable(?:-next-line|-line)?\s/ => /stylelint-disable(?:-next-line|-line)? [\w\/, -]+ -- \S/,
    /erb_?lint:disable\s/ => /erb_?lint:disable \w+: \S/,
    /zizmor: ?ignore\[/ => /zizmor: ignore\[[\w, -]+\] -- \S/,
    # ShellCheck can't parse anything after a directive but a comment
    /shellcheck disable=/ => /shellcheck disable=[\w,]+ # \S/
  }.freeze

  # Herb's disable comments take no reason, so it goes in an ERB comment on the line above
  HERB_DISABLE = /herb:(?:disable|linter ignore)\b/
  HERB_REASON = /\A\s*<%#(?!.*herb:).*\w.*%>\s*\z/

  def test_every_disable_says_why
    output, = Open3.capture2('git', 'ls-files', '-z', chdir: ROOT)
    paths = output.split("\0").grep(%r{\.(rb|rake|erb|js|mjs|css|sh)\z|\A\.github/.+\.ya?ml\z|\A\.githooks/}).grep_v(%r{\A(app/assets/javascripts/ext/|app/assets/stylesheets/bootstrap5\.css|ckeditor/|test/lint_test\.rb)})
    missing = paths.flat_map do |path|
      lines = File.readlines(File.join(ROOT, path), encoding: 'UTF-8')
      lines.each_with_index.filter_map do |line, index|
        unexplained = DISABLES.any? { |disable, with_reason| line.match?(disable) && !line.match?(with_reason) } ||
                      (line.match?(HERB_DISABLE) && !(index.positive? && lines[index - 1].match?(HERB_REASON)))
        unexplained && "#{path}:#{index + 1}: #{line.strip}"
      end
    end
    assert_empty missing, "Say why after the rule (-- reason, or Linter: reason for erb_lint, or in an ERB comment on the line above for Herb)"
  end

  def ci_test_groups
    YAML.load_file(File.join(ROOT, '.github/workflows/ruby.yml'))['jobs']['test']['strategy']['matrix']['include']
  end

  # CI lists its test jobs, each a group of test files, rather than finding them, so each test file needs to be in one
  def test_ci_runs_every_test_file
    listed = ci_test_groups.flat_map { |group| group['files'].split }
    files = Dir[File.join(ROOT, 'test/**/*_test.rb')].map { |f| f.delete_prefix(File.join(ROOT, 'test/')).delete_suffix('_test.rb') } - ['lint']
    assert_equal files.sort, listed.sort, 'Put each test file in one group in .github/workflows/ruby.yml, once'
  end

  # GitHub's Free plan runs 20 jobs at once across the organisation, and a push to master also starts the lint job,
  # CodeQL's 3 and Sentry release's 1. More test groups than this leaves some queued until others finish, as a second wave
  MAX_CI_TEST_GROUPS = 15

  def test_ci_test_groups_fit_in_one_wave_of_jobs
    assert_operator ci_test_groups.length, :<=, MAX_CI_TEST_GROUPS,
                    "Only #{MAX_CI_TEST_GROUPS} CI test jobs fit in one wave: add a new test file to an existing group in .github/workflows/ruby.yml, one that runs quickly, rather than a group of its own"
  end

  # AGENTS.md: only edit .mcp.json, then run rake mcp:sync to write the copies other tools read
  def test_mcp_copies_match_mcp_json
    load File.join(ROOT, 'tasks/mcp.rake')
    McpConfigFiles.files.each do |path, content|
      assert_equal content, File.read(File.join(ROOT, path), encoding: 'UTF-8'), "#{path} differs from .mcp.json: edit .mcp.json and run rake mcp:sync"
    end
  end

  # AGENTS.md, Dependencies: versions are exact, so a release can't arrive unchosen (and inside its 7-day cooldown)
  EXACT = /\A\d+\.\d+\.\d+\z/

  def test_dependency_versions_are_exact
    # ckeditor/ installs from its yarn.lock, which pins every version
    %w[package.json frontend/package.json].each do |manifest|
      JSON.parse(File.read(File.join(ROOT, manifest))).values_at('dependencies', 'devDependencies').compact.reduce({}, :merge).each do |name, version|
        assert_match EXACT, version, "#{manifest}: pin #{name} to an exact version"
      end
    end

    packages = cdn_urls.filter_map { |url| url[%r{/npm/((?:@[^/]+/)?[^/]+)/}, 1] }
    packages += Dir[File.join(ROOT, 'tasks/*.rake')].flat_map { |f| File.read(f, encoding: 'UTF-8').scan(/'((?:@[\w.-]+\/)?[\w.-]+@[^']+)'/).flatten }
    refute_empty packages
    packages.flatten.each do |package|
      assert_match EXACT, package.rpartition('@').last, "pin #{package} to an exact version"
    end
  end

  # Every CDN file the app loads (config/frontend_dependencies.rb)
  def cdn_urls
    path = File.join(ROOT, 'config/frontend_dependencies.rb')
    Module.new.tap { |m| m.module_eval(File.read(path), path) }::FRONTEND_CDN_URLS.call(ROOT).uniq
  end

  # AGENTS.md, Dependencies: each CDN file has the hash cdn_tag writes as its integrity attribute (CdnTags checks each
  # template's own), and no hash is left over
  def test_cdn_files_have_integrity
    integrity = JSON.parse(File.read(File.join(ROOT, 'frontend/integrity.json')))
    urls = cdn_urls
    refute_empty urls
    assert_empty urls - integrity.keys, 'run rake frontend:integrity to hash these CDN files'
    assert_empty integrity.keys - urls, 'nothing loads these: run rake frontend:integrity, which drops them'
    integrity.each { |url, hash| assert_match %r{\Asha384-[A-Za-z0-9+/]{64}\z}, hash, url }

    # frontend/package.json lists only what the app loads, so no package nothing uses is kept up to date or raises security alerts
    listed = JSON.parse(File.read(File.join(ROOT, 'frontend/package.json')))['dependencies'].keys
    loaded = urls.filter_map { |url| url[%r{/npm/((?:@[^/]+/)?[^/@]+)@}, 1] }.uniq
    assert_empty listed - loaded, 'nothing loads these: remove them from frontend/package.json'
  end

  def test_doc_claims_are_the_text_before_each_marker
    source = "Intro. <!-- claim: first --> Then  more. <!-- claim: second --> Untested.\n- An item <!-- claim: item -->\n> Quoted <!-- claim: quote -->\n"
    claims = DocClaims.claims(source)
    assert_equal([['first', 'Intro.', 1], ['second', 'Then more.', 1], ['item', 'An item', 2], ['quote', 'Quoted', 3]], claims.map { |c| c.values_at(:id, :text, :line) })
    assert_equal DocClaims.hash('Intro.'), claims.first[:hash]
    assert_equal "Intro. Then  more. Untested.\n- An item\n> Quoted\n", DocClaims.strip(source)
  end

  # AGENTS.md, Docs and tests: each claim the docs mark is covered by a test, checked against the claim's current text
  def test_doc_claims_are_tested
    claims = Dir[File.join(ROOT, 'app/views/docs/md/*.md')].flat_map do |path|
      page = File.basename(path, '.md')
      DocClaims.claims(File.read(path, encoding: 'UTF-8')).map { |c| c.merge(ref: "#{page}/#{c[:id]}", at: "app/views/docs/md/#{page}.md:#{c[:line]}") }
    end
    refute_empty claims
    duplicates = claims.group_by { |c| c[:ref] }.select { |_, cs| cs.size > 1 }.keys
    assert_empty duplicates, 'Give each claim on a page its own id'
    claims = claims.to_h { |c| [c[:ref], c] }

    covers = Dir[File.join(ROOT, 'test/**/*_test.rb')].flat_map do |path|
      File.readlines(path, encoding: 'UTF-8').each_with_index.flat_map do |line, index|
        line[/\A\s*covers ('.+)/, 1].to_s.scan(/'([^']*)'/).flatten.map { |ref| [ref, "#{path.delete_prefix("#{ROOT}/")}:#{index + 1}"] }
      end
    end
    problems = covers.filter_map do |ref, at|
      id, hash = ref.split('@')
      claim = claims[id]
      if claim.nil?
        "#{at}: no claim #{id} in the docs (covers 'page/id@hash')"
      elsif hash != claim[:hash]
        "#{at}: #{claim[:at]} has changed since this test was checked against it. Check the test still tests \"#{claim[:text]}\", then cover '#{id}@#{claim[:hash]}'"
      end
    end
    assert_empty problems, problems.join("\n")
    untested = claims.values.reject { |c| covers.any? { |ref, _| ref.split('@').first == c[:ref] } }.map { |c| "#{c[:at]}: #{c[:ref]}" }
    assert_empty untested, "No test covers these claims: write one and add covers '<ref>@<hash>' to it\n#{untested.join("\n")}"
  end

  def test_route_marks_read_routes_as_controllers_write_them
    assert_equal 'app/app.rb', RouteMarks.routes['GET /'].split(':').first
    assert RouteMarks.routes.key?('GET /dadmin/edit/:model/:id'), "a named controller's get :edit, map: '/path'"
    assert RouteMarks.routes.key?('POST /e/:slug/orders/:order_id/restore_and_complete')
  end

  # AGENTS.md, Tests: a test covering a route says so (covers_route), so a new route needs a test
  def test_every_route_is_covered
    routes = RouteMarks.routes
    marks = RouteMarks.marks
    problems = marks.reject { |route, _| routes.key?(route) }.map do |route, at|
      "#{at}: covers_route '#{route}' names no route: write it as 'VERB /path', the path as the controller writes it"
    end
    assert_empty problems, problems.join("\n")
    uncovered = (routes.keys - marks.map(&:first)).map { |route| "#{routes[route]}: #{route}" }
    assert_empty uncovered, "No test covers these routes: write one starting covers_route 'VERB /path'\n#{uncovered.join("\n")}"
  end

  # AGENTS.md, Tests: a helper is defined once, in its test file or in a module in test/helpers that the files sharing
  # it include, so two files' copies can't drift apart, nor one name mean two things. Only the methods of test classes
  # and helper modules count, not of the fakes a test defines (a class RecordedEmail's header)
  def test_test_helpers_are_defined_once
    defined = Hash.new { |hash, name| hash[name] = [] }
    Dir[File.join(ROOT, 'test/**/*.rb')].each do |path|
      owner = nil
      File.foreach(path, encoding: 'UTF-8').with_index(1) do |line, number|
        owner = Regexp.last_match(1) if line =~ /\A(?:class|module) (\w+)/
        next unless owner&.match?(/(Test|Helpers|TestCase)\z/) && line =~ /\A  def (?:self\.)?(\w+[?!=]?)/

        defined[Regexp.last_match(1)] << "#{path.delete_prefix("#{ROOT}/")}:#{number}"
      end
    end
    repeated = defined.select { |_, ats| ats.map { |at| at.split(':').first }.uniq.size > 1 }
    assert_empty repeated, "Define each test helper once: share it in a module in test/helpers, or give each its own name\n#{repeated.map { |name, ats| "#{name}: #{ats.join(', ')}" }.join("\n")}"
  end

  # AGENTS.md, Build/vendored code: CKEditor 38 and later show a Powered by CKEditor badge under the GPL
  def test_ckeditor_stays_on_37
    JSON.parse(File.read(File.join(ROOT, 'ckeditor/package.json'))).values_at('dependencies', 'devDependencies').compact.reduce({}, :merge).each do |name, version|
      assert_match(/\A[\^~]?37\./, version, "#{name} #{version}: keep CKEditor on 37") if name.start_with?('@ckeditor/', 'ckeditor5')
    end
  end

  def test_iframe_resizer_stays_on_4
    version = JSON.parse(File.read(File.join(ROOT, 'frontend/package.json')))['dependencies']['iframe-resizer']
    assert_match(/\A4\./, version, "iframe-resizer #{version}: keep iframe-resizer on 4")
  end

  def node_modules!
    skip 'needs ESLint, Stylelint and Herb installed (npm ci)' unless %w[eslint stylelint herb-lint].all? { |tool| File.exist?(File.join(ROOT, 'node_modules/.bin', tool)) }
  end

  # Lints sources with ESLint's or Stylelint's own API, all in one Node process, as starting the linter for each case took
  # most of this file's time. Takes [source, path] pairs and returns, for each, ESLint's messages or Stylelint's rules
  NODE_LINT = <<~JS.freeze
    import { readFileSync } from 'node:fs'
    import { resolve } from 'node:path'
    const { tool, cases } = JSON.parse(readFileSync(0, 'utf8'))
    const results = []
    if (tool === 'eslint') {
      const eslint = new (await import('eslint')).ESLint()
      for (const [code, file] of cases) results.push((await eslint.lintText(code, { filePath: resolve(file) }))[0].messages.map((m) => `${m.line}:${m.column} ${m.message}`))
    } else {
      const stylelint = (await import('stylelint')).default
      for (const [code, file] of cases) results.push((await stylelint.lint({ code, codeFilename: resolve(file) })).results[0].warnings.map((w) => file.endsWith('.erb') ? `${w.line}:${w.column} ${w.rule}` : w.rule))
    }
    process.stdout.write(JSON.stringify(results))
  JS

  def node_lint(tool, cases)
    output, status = Open3.capture2('node', '--input-type=module', '-e', NODE_LINT, stdin_data: { tool: tool, cases: cases }.to_json, chdir: ROOT)
    assert status.success?, "#{tool} didn't run"
    JSON.parse(output)
  end

  def test_eslint_rules
    node_modules!
    bad = {
      %(/* global el */\nel.classList.add('d-none')) => /d-none/,
      %($('#x').html(`<span class="badge text-bg-success">${1}</span>`)) => /-success/,
      %($('#x').html('<span class="badge badge-info">')) => /badge-\*/,
      %($('#x').html('<span class="label">')) => /\.label/,
      %($('#x').addClass('mr-3')) => /ms-\*/,
      %($('#x').attr('data-toggle', 'tooltip')) => /data-bs-\*/,
      %($('#x').html('<select name="y">')) => /form-select/,
      %(fetch('/x').then(function (response) { return response.text() })) => /jQuery/
    }
    good = %($('#x').html('<label class="form-label ms-2 media" data-bs-toggle="x"><select class="form-select">').addClass('text-end').removeClass('with-label'))
    *results, good_result = node_lint('eslint', [*bad.keys, good].map { |source| [source, 'app/assets/javascripts/x.js'] })
    bad.each_with_index do |(source, message), index|
      assert_equal 1, results[index].size, "ESLint on #{source}: #{results[index].inspect}"
      assert_match message, results[index].first
    end
    assert_empty good_result, 'ESLint flags Bootstrap 5 and our own classes'
  end

  # eslint.config.mjs lints a template's inline scripts and event attributes, where they are in the template
  def test_eslint_lints_templates
    node_modules!
    template = <<~ERB
      <a href="#" onclick="$(this).addClass('d-none'); return false">x</a>
      <% if x %>
        <script>
          var url = <%== '/x'.to_json %> + '<%= y %>'
          fetch(url)
        </script>
      <% end %>
      <script type="application/json">{"a": <%== 1 %>}</script>
      <script src="<%= z %>"></script>
      <button onclick="go(<%= w.to_json %>)" onmouseover="return true">y</button>
      <script type = "application/json">{"b": 2}</script>
      <a onClick = "x(&quot;y&quot;) &amp;&amp; $(this).hide()">z</a><script>fetch('/z')</script>
    ERB
    messages, = node_lint('eslint', [[template, 'app/views/x.erb']])
    assert_equal 5, messages.size, messages.inspect
    assert_match(/\A1:39 .*d-none/, messages[0])
    assert_match(/\A5:5 .*jQuery/, messages[1])
    assert_match(/\A10:18 .*'go' is not defined/, messages[2])
    # Spaced, mixed-case event attributes, with HTML entities, which move no columns
    assert_match(/\A12:15 .*'x' is not defined/, messages[3])
    assert_match(/\A12:72 .*jQuery/, messages[4])
  end

  def test_stylelint_rules
    node_modules!
    bad = {
      '.a { color: #fff; }' => 'declaration-property-value-disallowed-list',
      '.a { color: rgba(0, 0, 0, 0.5); }' => 'declaration-property-value-disallowed-list',
      '.a { color: white; }' => 'color-named',
      '.a { border-radius: 7px; }' => 'declaration-property-value-disallowed-list',
      '.a { box-shadow: 0 2px 9px var(--x); }' => 'declaration-property-value-disallowed-list',
      '.a { margin-left: 4px; }' => 'declaration-property-unit-disallowed-list',
      '.a { top: 12px; }' => 'declaration-property-unit-disallowed-list',
      '.a { transition: all var(--transition-fast); }' => 'declaration-property-value-disallowed-list',
      '.a { transition-property: color, transform; }' => 'declaration-property-value-disallowed-list',
      '.a { transition: opacity 0.3s ease; }' => 'declaration-property-value-disallowed-list',
      '.a { animation: pulse 1s infinite; }' => 'declaration-property-value-disallowed-list'
    }
    good = <<~CSS
      .a { --c: #fff; color: rgba(var(--bs-black-rgb), 0.5); background: transparent; border: 1px solid var(--hairline); }
      .c { transition: opacity var(--transition-enter), translate var(--transition-enter), rotate var(--transition-fast), --fade-start var(--transition-fast); }
      .d { transition: none; animation: spin 2s linear; transform: translateY(50%); }
      .b { border-radius: 0 0 var(--bs-border-radius) 50%; box-shadow: inset 0 0 0 1px var(--x), var(--bs-box-shadow); margin: var(--space-xs) 0.375rem; }
    CSS
    cases = [*bad.keys, good].map { |source| [source, 'app/assets/stylesheets/x.css'] } << ['.a { color: var(--x); }', 'app/assets/stylesheets/email.css']
    *results, good_result, email_result = node_lint('stylelint', cases)
    bad.each_with_index { |(source, rule), index| assert_equal [rule], results[index], source }
    assert_empty good_result
    assert_equal ['declaration-property-value-disallowed-list'], email_result
  end

  # stylelint.config.mjs checks a template's <style>s and style attributes, where they are in the template
  def test_stylelint_lints_templates
    node_modules!
    template = <<~ERB
      <style>
        .a { color: #fff; margin: <%= x %>; }
        <%= 'b { c: d }' %>
      </style>
      <div style="<%= 'display: none' if y %>; border-radius: 4px; color: var(--theme-500)" class="z">
      <%# stylelint-disable-next-line declaration-property-unit-disallowed-list -- a reason %>
      <p style="padding: 3px"><p style = 'margin: <%= z %>px'>
    ERB
    email = %(<div style="color: #333; padding: 12px">\n<p style="color: var(--x)">)
    messages, email_messages = node_lint('stylelint', [[template, 'app/views/x.erb'], [email, 'app/views/emails/x.erb']])
    assert_equal ['2:15 declaration-property-value-disallowed-list', '5:57 declaration-property-value-disallowed-list'], messages
    assert_equal ['2:18 declaration-property-value-disallowed-list'], email_messages
  end

  # The rules .herb.yml turns on, and none of those it leaves off (Rails conventions and style)
  def test_herb_rules
    node_modules!
    bad = {
      '<h2>x</h1>' => 'parser-no-errors',
      "<% xs.each { |x| if x %>\n  <p>a</p>\n<% end } %>" => 'parser-no-errors',
      '<a class="a" class="b">x</a>' => 'html-no-duplicate-attributes',
      '<i class="bi bi-x" />' => 'html-no-self-closing',
      '<img src="a.png">' => 'html-img-require-alt',
      '<iframe src="/x"></iframe>' => 'html-iframe-has-title',
      '<h3></h3>' => 'html-no-empty-headings',
      '<input type="text" aria-hidden="true">' => 'html-no-aria-hidden-on-focusable',
      '<% x = 1 %>' => 'erb-no-unused-local-variable',
      "<% if x %>\n<% else %>\n  <p>a</p>\n<% end %>" => 'erb-no-empty-control-flow'
    }
    good = <<~ERB
      <% @events.each { |event| %>
        <img alt="" src="<%= event.image_url %>">
        <a href="#" data-confirm="Sure?" data-method="post">x</a>
      <% } %>
      <script>var a = 1</script>
      <% case x %>
      <% when 1 %>
        <h2 class="h4">y</h2>
      <% end %>
      <%# sheets.js fills it in %>
      <h3></h3> <%# herb:disable html-no-empty-headings %>
    ERB
    Dir.mktmpdir do |dir|
      files = [*bad.keys, good].each_with_index.map { |source, index| File.join(dir, "_#{index}.erb").tap { |f| File.write(f, source) } }
      output, = Open3.capture2('npx', '--no-install', 'herb-lint', '--config-file', '.herb.yml', '--force', '--json', *files, chdir: ROOT)
      offenses = JSON.parse(output)['offenses'].group_by { |offense| File.basename(offense['filename']) }
      bad.each_with_index do |(source, rule), index|
        assert_equal [rule], offenses.fetch("_#{index}.erb", []).map { |offense| offense['code'] }.uniq, source
      end
      assert_nil offenses["_#{bad.size}.erb"], 'Herb flags Rails conventions or a disabled line'
    end
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
    assert_match(/Passed: RuboCop, erb_lint, ESLint, Stylelint, Herb/, output)
  end

  def test_script_lint_fails_on_a_built_file_without_its_source
    # --only eslint leaves these no files to lint, so only the check for built files runs
    output, status = lint('--only', 'eslint', 'app/assets/stylesheets/bootstrap5.css')
    refute status.success?, output
    assert_match(/bootstrap5.css is built from bootstrap5.scss/, output)
    output, status = lint('--only', 'eslint', 'app/assets/javascripts/ext/ckeditor.js')
    refute status.success?, output
    assert_match(/ckeditor.js is built from ckeditor/, output)
    output, status = lint('--only', 'eslint', 'app/assets/javascripts/ext/jquery-ui-autocomplete.min.js')
    refute status.success?, output
    assert_match(/jquery-ui-autocomplete.min.js is built from jQuery UI/, output)

    [%w[app/assets/stylesheets/bootstrap5.css app/assets/stylesheets/bootstrap5.scss], %w[app/assets/javascripts/ext/ckeditor.js ckeditor/yarn.lock],
     %w[app/assets/javascripts/ext/jquery-ui-autocomplete.min.js tasks/build.rake]].each do |files|
      output, status = lint('--only', 'eslint', *files)
      assert status.success?, output
    end
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

  def test_script_lint_runs_shellcheck
    skip 'needs uv installed' unless ENV['PATH'].split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, 'uvx')) }
    Dir.mktmpdir do |dir|
      bad = File.join(dir, 'bad.sh')
      File.write(bad, "#!/bin/sh\necho $1\n") # SC2086, unquoted
      output, status = lint(bad)
      refute status.success?, output
      assert_match(/SC2086/, output)

      good = File.join(dir, 'good.sh')
      File.write(good, "#!/bin/sh\n# shellcheck disable=SC2086 # splits on purpose\necho $1\n")
      output, status = lint(good)
      assert status.success?, output
    end
  end

  def test_script_lint_runs_actionlint
    skip 'needs uv installed' unless ENV['PATH'].split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, 'uvx')) }
    Dir.mktmpdir do |dir|
      # A workflow in a copy of the checkout's script/ and actionlint config, as script/lint runs from its parent, made
      # a git repository, where actionlint looks for its config. Git exports GIT_DIR and others to hooks, so in the
      # pre-commit hook git init would reinitialise the checkout's own repository (setting core.bare in its config) and
      # actionlint would look there: both run without them
      no_git_env = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
      _, status = Open3.capture2e(no_git_env, 'git', 'init', '-q', dir)
      assert status.success?
      assert File.directory?(File.join(dir, '.git'))
      FileUtils.mkdir_p(File.join(dir, '.github/workflows'))
      FileUtils.cp_r(File.join(ROOT, 'script'), dir)
      FileUtils.cp(File.join(ROOT, '.github/actionlint.yaml'), File.join(dir, '.github'))
      bad = File.join(dir, '.github/workflows/bad.yml')
      File.write(bad, <<~YAML)
        on: push
        jobs:
          x:
            runs-on: ubuntu-latest
            steps:
              - uses: $/.github/actions/ours
              - run: echo ${{ github.event.nope.x }} >> $GITHUB_ENV
      YAML
      output, status = Open3.capture2e(no_git_env, 'script/lint', '--only', 'actionlint', '.github/workflows/bad.yml', chdir: dir)
      output = output.force_encoding('UTF-8') # actionlint underlines with ^~~
      refute status.success?, output
      assert_match(/SC2086/, output) # ShellCheck, on the run: script
      refute_match(%r{actions/ours}, output) # the $/ self-repository syntax is fine
    end
  end
end
