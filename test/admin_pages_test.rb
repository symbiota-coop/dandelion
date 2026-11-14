require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# Each page admins see, for records with every optional field empty, plus a few awkward-but-valid cases (an online
# event, one with no ticket types, one whose creator, organiser, revenue sharer, facilitator and buyer have deleted their
# accounts, a shift no one has taken), so a template that raises for some combination of data fails here. The pages are
# the GET routes whose code (or its controller's before filter) calls an admin or membership guard, read by
# lib/route_marks.rb, so a new admin page is visited without being added here. Each loads for a site admin and for the
# record's own admin with no server or JavaScript error and, if it's a whole page, shows its record's name. A route
# that renders a partial is a pagelet, loaded into a page with jQuery as pagelets.js loads it, and one whose code
# answers XHR differently is loaded both ways
class AdminPagesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # A guard of the record's admins or members, or of site admins only
  RECORD_GUARD = /\b\w+_admins\w*_only!|\b(?:confirmed_)?membership_required!/
  SITE_ADMIN_GUARD = /\badmins_only!/
  # Controllers whose pages are about no one record (site admins'), or answer programs (Zapier) rather than people
  UNVISITED_FILES = %w[dadmin messages recommendations stats zapier].map { |name| "app/controllers/#{name}.rb" }.freeze
  # Controllers whose before filter finds the record from a query string, so their pages are visited for each kind of
  # record they serve
  SCOPED_FILES = %w[app/controllers/pmails.rb app/controllers/discount_codes.rb].freeze

  # Routes not visited, and why
  SKIP = {
    # Actions, not pages: they change something and redirect
    'GET /e/:slug/hide_from_homepage' => 'hides the event, then redirects',
    'GET /e/:slug/duplicate' => 'makes a copy of the event, then redirects to it',
    'GET /g/:slug/copy' => 'makes a copy of the gathering, then redirects to it',
    'GET /g/:slug/subscribe' => 'subscribes to the gathering, then redirects',
    'GET /g/:slug/unsubscribe' => 'unsubscribes from the gathering, then redirects',
    'GET /o/:organisation_slug/a/:slug/activity_applications/:activity_application_id/set_status' => 'changes the application, then redirects',
    'GET /g/:slug/teamships/:id/subscribe' => 'subscribes, then redirects',
    'GET /g/:slug/teamships/:id/unsubscribe' => 'unsubscribes, then redirects',
    'GET /g/:slug/teams/:id/unsubscribe' => 'unsubscribes, then redirects',
    'GET /g/:slug/rotas/:id/create_shift' => 'books a shift',
    # Needs what can't be made here
    'GET /e/:slug/check_in' => "the QR scanner asks for a camera, which headless Chrome hasn't got",
    'GET /e/:slug/linked_image' => "shows the image an event takes from its organisation's, which bare records haven't got",
    'GET /e/:slug/stripe_report' => 'is a 404 unless the organisation has a Stripe Connect account, which needs Stripe',
    'GET /e/:slug/feedback_report' => 'is a 404 until the event has 5 answered feedbacks, and then asks OpenRouter',
    'GET /o/:slug/stripe_setup_complete' => "Stripe's return from checkout, which needs a Stripe session",
    'GET /organisations/stripe_connect' => "Stripe Connect's OAuth return, which needs Stripe",
    'GET /o/:slug/atproto/connect' => 'starts an OAuth flow with a Bluesky server',
    'GET /pmails/:oid/attachments' => 'lists uploads to S3',
    'GET /g/:slug/payments/:payment_id' => 'polls a crypto payment, which needs a chain to look at'
  }.freeze

  # Routes that redirect as they should, and why
  REDIRECTS = {
    'GET /g/:slug/rotas' => 'goes to the only rota'
  }.freeze

  # Whole pages that don't show their record's name, and why
  NAMELESS = {
    'GET /activities/new' => "a form for a new activity, which doesn't name its organisation",
    'GET /local_groups/new' => "a form for a new local group, which doesn't name its organisation",
    'GET /orders/:id/transfer' => "names the buyer, not the event (the event's link is 'Return to event')"
  }.freeze

  # Query strings routes need
  QUERIES = {
    'GET /activities/new' => ->(test) { "organisation_id=#{test.organisation.id}" },
    'GET /local_groups/new' => ->(test) { "organisation_id=#{test.organisation.id}" }
  }.freeze

  attr_reader :organisation

  # [route, its file, its code, its controller's before filter] for each admin page
  def self.admin_routes
    RouteMarks.routes.filter_map do |route, at|
      file, line = at.split(':')
      next if !route.start_with?('GET ') || UNVISITED_FILES.include?(file) || SKIP.key?(route)

      lines = File.readlines(file, encoding: 'UTF-8')
      body = lines[line.to_i..].take_while { |code| !code.match?(RouteMarks::DEFINITION) && !code.match?(RouteMarks::VERBS) }.join
      before = lines.join[/^  before do\n.*?^  end\n/m].to_s
      [route, file, body, before] if (before + body).match?(Regexp.union(RECORD_GUARD, SITE_ADMIN_GUARD))
    end
  end

  # Records

  def awkward_account
    FactoryBot.create(:account, location: nil)
  end

  # An order with one ticket, of the event's first ticket type if it has one
  def create_order(event, buyer: awkward_account)
    order = event.orders.create!(account: buyer, currency: event.currency, value: 0, payment_completed: true)
    order.tickets.create!(event: event, account: buyer, ticket_type: event.ticket_types.first, price: 0)
    order
  end

  def create_records
    creator = awkward_account
    @own_admin = awkward_account
    @organisation = FactoryBot.create(:organisation, account: creator, stripe_pk: nil, stripe_sk: nil)
    @organisation.organisationships.create!(account: @own_admin, admin: true)
    @activity = FactoryBot.create(:activity, organisation: @organisation, account: @own_admin)
    @local_group = FactoryBot.create(:local_group, organisation: @organisation, account: @own_admin)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @own_admin, prices: [0])
    @events = [
      @event,
      FactoryBot.create(:event, organisation: @organisation, account: @own_admin, location: 'Online', prices: [0]),
      FactoryBot.create(:event, organisation: @organisation, account: @own_admin) # no ticket types
    ]
    gone = Array.new(5) { awkward_account }
    event = FactoryBot.create(:event, organisation: @organisation, account: @own_admin, prices: [0])
    # Set straight, as validations allow an organiser or a revenue sharer, not both: deleting the accounts unsets them
    event.set(account_id: gone[0].id, last_saved_by_id: gone[0].id, organiser_id: gone[1].id, revenue_sharer_id: gone[2].id,
              revenue_share_to_revenue_sharer: 10)
    event.event_facilitations.create!(account: gone[3])
    create_order(event, buyer: gone[4])
    @events << event
    @events.each do |each_event|
      create_order(each_event) unless each_event.orders.exists?
      each_event.rpayments.create!(account: @own_admin, amount: 10, currency: 'GBP', role: Rpayment.roles.first)
    end
    # The organisation's creator deletes their account too
    (gone + [creator]).each { |account| Account.find(account.id).destroy }

    create_organisation_records
    create_gathering_records
  end

  def create_organisation_records
    @carousel = FactoryBot.create(:carousel, organisation: @organisation)
    @organisation_tier = @organisation.organisation_tiers.create!(name: 'Friends', threshold: 10, discount: 5)
    @organisationship = @organisation.organisationships.find_by(account: @own_admin)
    @activityship = @activity.activityships.find_by(account: @own_admin)
    @local_groupship = @local_group.local_groupships.find_by(account: @own_admin)
    @activity_application = @activity.activity_applications.create!(account: awkward_account)
    @event_feedback = @event.event_feedbacks.create!(account: @event.orders.first.account, publicly_visible: true)
    # A mail and a discount code for each kind of record that sends them, with the query string their pages take
    @scopes = { @organisation => 'everyone', @activity => "activity:#{@activity.id}", @local_group => "local_group:#{@local_group.id}",
                @event => "event:#{@event.id}" }.to_h do |record, to_option|
      pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @own_admin, to_option: to_option)
      discount_code = record.discount_codes.create!(code: "CODE#{record.id}", percentage_discount: 10)
      ["#{record.class.name.underscore}_id=#{record.id}", { record: record, pmail: pmail, discount_code: discount_code }]
    end
  end

  def create_gathering_records
    @gathering = FactoryBot.create(:gathering, account: @own_admin)
    @membership = @gathering.memberships.find_by(account: @own_admin)
    @mapplication = @gathering.mapplications.create!(account: awkward_account, status: 'pending')
    @option = @gathering.options.create!(name: 'Tent', account: @own_admin)
    @optionship = @option.optionships.create!(account: @own_admin, gathering: @gathering, membership: @membership)
    @team = @gathering.teams.create!(name: 'Kitchen', account: @own_admin)
    @teamship = @team.teamships.create!(account: @own_admin, gathering: @gathering, membership: @membership)
    @spend = @gathering.spends.create!(item: 'Pans', amount: 10, team: @team, account: @own_admin, membership: @membership)
    @inventory_item = @gathering.inventory_items.create!(name: 'Pans', account: @own_admin, membership: @membership, team: @team)
    @rota = @gathering.rotas.create!(name: 'Cooking', account: @own_admin)
    @role = @rota.roles.create!(name: 'Cook')
    @rslot = @rota.rslots.create!(name: 'Morning')
    # A shift marked not needed, which no one takes
    @shift = @rota.shifts.create!(role: @role, rslot: @rslot, gathering: @gathering)
    @timetable = @gathering.timetables.create!(name: 'Workshops', account: @own_admin)
    @tactivity = @timetable.tactivities.create!(name: 'Yoga', account: @own_admin)
  end

  # Paths

  # What fills each param, by the segment before it, for event, the event pages are visited for, and scope, the
  # records of a controller that finds them from a query string
  def param_value(segment, param, event, scope)
    order = event.orders.first
    ticket = order.tickets.first
    {
      'o/:slug' => @organisation.slug, 'o/:organisation_slug' => @organisation.slug,
      'a/:slug' => @activity.slug, 'lg/:slug' => @local_group.slug,
      'e/:slug' => event.slug, 'e/:event_slug' => event.slug, 'g/:slug' => @gathering.slug,
      # Routes find an order or ticket in a URL people are sent by its public id, and an admin's by its id
      'orders/:id' => order.id, 'orders/:order_id' => order.public_id,
      'tickets/:id' => ticket.id, 'ticketholders/:ticket_id' => ticket.public_id, 'check_in_toggle/:ticket_id' => ticket.public_id,
      'pmails/:pmail_id' => scope&.dig(:pmail)&.id, 'discount_codes/:discount_code_id' => scope&.dig(:discount_code)&.id,
      'organisationships/:id' => @organisationship.id, 'event_manager/:organisationship_id' => @organisationship.id,
      'subscribed/:organisationship_id' => @organisationship.id, 'subscribed/:activityship_id' => @activityship.id,
      'subscribed/:local_groupship_id' => @local_groupship.id,
      'carousels/:id' => @carousel.id, 'carousels/:carousel_id' => @carousel.id,
      'organisation_tiers/:organisation_tier_id' => @organisation_tier.id,
      'activity_applications/:activity_application_id' => @activity_application.id,
      'event_feedbacks/:id' => @event_feedback.id, 'public_answers/:i' => 0, 'rpayments/:id' => event.rpayments.first.id,
      'memberships/:id' => @membership.id, 'membership_row/:id' => @membership.id,
      'mapplications/:id' => @mapplication.id, 'mapplication_row/:id' => @mapplication.id,
      'options/:id' => @option.id, 'optionships/:id' => @optionship.id,
      'teams/:id' => @team.id, 'teamships/:id' => @teamship.id, 'spends/:id' => @spend.id,
      'inventory_items/:id' => @inventory_item.id, 'rotas/:id' => @rota.id, 'roles/:id' => @role.id,
      'rslots/:id' => @rslot.id, 'shifts/:id' => @shift.id, 'timetables/:id' => @timetable.id, 'tactivities/:id' => @tactivity.id
    }.fetch("#{segment}/:#{param}") { flunk "Add a record for #{segment}/:#{param} to #{self.class.name}, or SKIP its route" }
  end

  # [path, the name its page shows] for each visit to route
  def visits(route, file, events:)
    path = route.delete_prefix('GET ')
    fill = ->(event, scope) { path.gsub(%r{([\w-]+)/:(\w+)}) { "#{Regexp.last_match(1)}/#{param_value(Regexp.last_match(1), Regexp.last_match(2), event, scope)}" } }
    if SCOPED_FILES.include?(file)
      @scopes.map { |query, scope| ["#{fill.call(@event, scope)}?#{query}", scope[:record].name] }
    elsif path.start_with?('/e/', '/orders/', '/tickets/', '/event_feedbacks/')
      (path.include?('event_feedbacks') ? [@event] : events).map { |event| [fill.call(event, nil), event.name] }
    else
      query = QUERIES[route]&.call(self)
      [["#{fill.call(@event, nil)}#{"?#{query}" if query}", name_for(path)]]
    end
  end

  def name_for(path)
    case path
    when %r{\A/o/[^/]+/a/} then @activity.name
    when %r{\A/o/[^/]+/lg/} then @local_group.name
    when %r{\A/(o|organisationships|activities|local_groups)/} then @organisation.name
    when %r{\A/g/} then @gathering.name
    else @event.name
    end
  end

  # Visiting

  # The page pagelets are loaded into: it has the layout, jQuery and pagelets.js, and no CKEditor, which a page loads once
  HOST = '/accounts/subscriptions'.freeze

  # The error the server raised answering the last request, if any, cleared so it's raised once, here
  def raise_server_error
    error = Capybara.current_session.server.error
    return unless error

    Capybara.current_session.server.reset_error!
    raise error
  end

  # Requests path from the page, as a link would or as pagelets.js does (xhr), returning [status, whether it redirected,
  # whether it's a whole page]. With insert, a pagelet is put into the page, running its scripts
  def request_from_page(path, xhr: false, insert: false)
    answer = page.evaluate_async_script(<<~JS, path, xhr, insert)
      var path = arguments[0], xhr = arguments[1], insert = arguments[2], done = arguments[arguments.length - 1]
      fetch(path, { headers: xhr ? { 'X-Requested-With': 'XMLHttpRequest' } : {} }).then(function (response) {
        return response.text().then(function (text) {
          var whole = text.indexOf('id="page-container"') !== -1
          if (insert && response.status === 200 && !whole) $('#content').html(text)
          setTimeout(function () { done([response.status, response.redirected, whole]) }, insert ? 50 : 0)
        })
      })
    JS
    raise_server_error
    answer
  end

  # What's wrong with route's page at path, if anything. A whole page is visited, and if its code answers XHR
  # differently, loaded into itself as XHR too, as such a page loads its pagelet. A pagelet is put into the host page
  def problem_with(route, code, path, name)
    status, redirected, whole = request_from_page(path)
    xhr_branch = code.include?('request.xhr?')
    if whole && !(redirected && xhr_branch)
      problem_with_page(route, path, name) || (problem_with_pagelet(path, xhr: true, host: false) if xhr_branch)
    elsif status != 200 || (redirected && !xhr_branch)
      "answered #{status}#{' after redirecting' if redirected}"
    else
      problem_with_pagelet(path, xhr: xhr_branch)
    end
  end

  def problem_with_page(route, path, name)
    visit path
    @host_clean = false
    raise_server_error
    return "answered #{page.status_code}" unless page.status_code == 200
    return "redirected to #{page.current_path}" unless REDIRECTS.key?(route) || page.has_current_path?(path.split('?').first, ignore_query: true, wait: 0)
    return "doesn't show #{name}" unless NAMELESS.key?(route) || page.has_text?(name, wait: 0)

    nil
  end

  def problem_with_pagelet(path, xhr:, host: true)
    visit_host if host
    @host_clean = false
    status, = request_from_page(path, xhr: xhr, insert: true)
    "answered #{status}#{' to XHR' if xhr}" unless status == 200
  end

  # The host page, fresh unless nothing has been put into it since it loaded
  def visit_host
    visit HOST unless @host_clean
    @host_clean = true
  end

  def problem_visiting(route, code, path, name)
    problem_with(route, code, path, name)
  rescue StandardError => e
    Capybara.reset_sessions!
    @host_clean = false
    sign_in(@signed_in)
    "#{e.class}: #{e.message.lines.first.strip} #{e.backtrace.grep(%r{/dandelion/(app|models|lib)/}).first(2).join(' ')}"
  end

  # [route, path, problem] for each admin page that went wrong, signed in as account. Site admins see each event's
  # pages, and the record's own admin the first's, as what differs for them is what they may do, not the data
  def problems_as(account, site_admin:)
    @signed_in = account
    @host_clean = false
    sign_in(account)
    self.class.admin_routes.flat_map do |route, file, code, before|
      next [] unless site_admin || (before + code).match?(RECORD_GUARD)

      visits(route, file, events: site_admin ? @events : [@event]).filter_map do |path, name|
        (problem = problem_visiting(route, code, path, name)) && [route, path, problem]
      end
    end
  end

  test 'admin pages load for bare records, for site admins and their own admins' do
    create_records
    problems = problems_as(FactoryBot.create(:account, admin: true), site_admin: true).map { |problem| ['site admin:', *problem] }
    problems += problems_as(@own_admin, site_admin: false).map { |problem| ['own admin:', *problem] }
    assert problems.empty?, problems.map { |problem| problem.join(' ') }.join("\n")
  end

  test "an admin's check-in switch for a ticket that's gone, cancelled after the list loaded, is a 404" do
    covers_route 'GET /e/:slug/check_in_toggle/:ticket_id'
    create_event(prices: [0])
    ticket = @event.tickets.create!(account: FactoryBot.create(:account), ticket_type: @event.ticket_types.first, payment_completed: true)
    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/check_in_toggle/#{ticket.public_id}"
    assert_equal 200, last_response.status
    ticket.destroy
    get "/e/#{@event.slug}/check_in_toggle/#{ticket.public_id}"
    assert_equal 404, last_response.status
  end
end
