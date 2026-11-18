require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require_relative 'helpers/admin_pages_helpers'

# Each page admins see (AdminPagesHelpers), requested for each of its records, bare and awkward, as a site admin and as
# the record's own admin, answers with no server error and, if it's a whole page, shows its record's name. A route
# whose code answers XHR differently is requested both ways. These are requests a program could make, so they don't
# run the pages' scripts: test/admin_pages_browser_test.rb opens each page once in the browser for those
class AdminPagesTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include AdminPagesHelpers

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze

  # Requests path as a link would, or as pagelets.js does (xhr), following redirects with the same headers, as fetch
  # does. Returns [status, whether it redirected, the path it ended at, the body]
  def request_page(path, xhr: false)
    headers = xhr ? XHR : {}
    get path, {}, headers
    redirects = 0
    while last_response.redirect? && redirects < 5
      redirects += 1
      get last_response['Location'], {}, headers
    end
    [last_response.status, redirects.positive?, last_request.path, last_response.body]
  end

  def shows?(body, name)
    Nokogiri::HTML(body).text.include?(name)
  end

  # What's wrong with route's page at path, if anything. A whole page shows its name, and if its code answers XHR
  # differently, answers XHR too, as such a page loads its pagelet
  def problem_with_response(route, code, path, name)
    status, redirected, ended_at, body = request_page(path)
    xhr_branch = code.include?('request.xhr?')
    if body.include?('id="page-container"') && !(redirected && xhr_branch)
      return "answered #{status}" unless status == 200
      return "redirected to #{ended_at}" if redirected && !REDIRECTS.key?(route)
      return "doesn't show #{name}" unless NAMELESS.key?(route) || shows?(body, name)

      problem_with_xhr(path) if xhr_branch
    elsif status != 200 || (redirected && !xhr_branch)
      "answered #{status}#{' after redirecting' if redirected}"
    elsif xhr_branch
      problem_with_xhr(path)
    end
  end

  def problem_with_xhr(path)
    status, = request_page(path, xhr: true)
    "answered #{status} to XHR" unless status == 200
  end

  def problem_requesting(route, code, path, name)
    problem_with_response(route, code, path, name)
  rescue StandardError => e
    describe_error(e)
  end

  # [route, path, problem] for each admin page that went wrong, signed in as account. Site admins see each event's
  # pages, and the record's own admin the first's, as what differs for them is what they may do, not the data
  def problems_as(account, site_admin:)
    sign_in_with_rack(account)
    admin_routes_for(site_admin: site_admin).flat_map do |route, file, code, _before|
      visits(route, file, events: site_admin ? @events : [@event]).filter_map do |path, name|
        (problem = problem_requesting(route, code, path, name)) && [route, path, problem]
      end
    end
  end

  test 'admin pages load for bare and awkward records, for site admins and their own admins' do
    create_records
    problems = problems_as(FactoryBot.create(:account, admin: true), site_admin: true).map { |problem| ['site admin:', *problem] }
    problems += problems_as(@own_admin, site_admin: false).map { |problem| ['own admin:', *problem] }
    assert_empty problems, problems.map { |problem| problem.join(' ') }.join("\n")
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
