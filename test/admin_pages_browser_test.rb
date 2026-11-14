require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require_relative 'helpers/admin_pages_helpers'

# Each page admins see (AdminPagesHelpers) opens in the browser, once, for a site admin and the bare event, with no
# server or JavaScript error. A route that renders a partial is a pagelet, loaded into a page with jQuery as
# pagelets.js loads it, so its scripts run, and one whose code answers XHR differently is loaded both ways.
# test/admin_pages_test.rb requests them for every record and admin, which needs no browser
class AdminPagesBrowserTest < ActiveSupport::TestCase
  include Capybara::DSL
  include AdminPagesHelpers

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
  def problem_with(route, code, path)
    status, redirected, whole = request_from_page(path)
    xhr_branch = code.include?('request.xhr?')
    if whole && !(redirected && xhr_branch)
      problem_with_page(route, path) || (problem_with_pagelet(path, xhr: true, host: false) if xhr_branch)
    elsif status != 200 || (redirected && !xhr_branch)
      "answered #{status}#{' after redirecting' if redirected}"
    else
      problem_with_pagelet(path, xhr: xhr_branch)
    end
  end

  def problem_with_page(route, path)
    visit path
    @host_clean = false
    raise_server_error
    return "answered #{page.status_code}" unless page.status_code == 200
    return "redirected to #{page.current_path}" unless REDIRECTS.key?(route) || page.has_current_path?(path.split('?').first, ignore_query: true, wait: 0)

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

  def problem_visiting(route, code, path)
    problem_with(route, code, path)
  rescue StandardError => e
    Capybara.reset_sessions!
    @host_clean = false
    sign_in(@signed_in)
    describe_error(e)
  end

  # Signs in a site admin, @signed_in, signed in again after a page raises
  def sign_in_site_admin
    @signed_in = FactoryBot.create(:account, admin: true)
    @host_clean = false
    sign_in(@signed_in)
  end

  test 'admin pages open with no server or JavaScript error' do
    create_records
    sign_in_site_admin
    problems = admin_routes_for(site_admin: true).filter_map do |route, file, code, _before|
      path, = visits(route, file, events: [@event]).first
      (problem = problem_visiting(route, code, path)) && [route, path, problem]
    end
    assert problems.empty?, problems.map { |problem| problem.join(' ') }.join("\n")
  end
end
