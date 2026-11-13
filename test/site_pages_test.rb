require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# The site's own pages, as a person sees them: the policies, contact, features and comparison pages, the code and
# docs, the library, a location's page, recommendations, referral rewards, feedback and questions to us, and the sidebar
class SitePagesTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'the policy, contact, features and comparison pages are open to anyone' do
    covers_route 'GET /privacy', 'GET /cookies', 'GET /terms', 'GET /contact', 'GET /features', 'GET /dandelion-vs-luma'
    {
      '/privacy' => 'Privacy Policy',
      '/cookies' => 'Cookie Policy',
      '/terms' => 'Dandelion Terms and Conditions',
      '/contact' => 'Contact us',
      '/features' => 'Events & Ticketing',
      '/dandelion-vs-luma' => 'Why organisers are switching'
    }.each do |path, heading|
      visit path
      assert page.has_css?('h1, h2', text: heading), "#{path} has no #{heading}"
    end
  end

  test 'the code page lists the latest commits, by day, from GitHub' do
    covers_route 'GET /code'
    commit = lambda do |sha, message, date|
      { 'sha' => sha, 'html_url' => "https://github.com/symbiota-coop/dandelion/commit/#{sha}", 'commit' => { 'message' => message, 'author' => { 'date' => date } } }
    end
    commits = [commit.('abcdef1234567', 'Test the site pages', '2026-11-12T10:00:00Z'), commit.('1234567abcdef', 'Fix a typo', '2026-11-10T10:00:00Z')]
    requested = []
    Github.stub(:get, lambda { |path, params|
      requested << [path, params]
      commits
    }) do
      visit '/code'
      assert page.has_content?('Commits on Nov 12, 2026')
      assert page.has_link?('abcdef1', href: 'https://github.com/symbiota-coop/dandelion/commit/abcdef1234567')
      assert page.has_content?('Test the site pages')
      assert page.has_content?('Commits on Nov 10, 2026')
      assert page.has_content?('Fix a typo')
    end
    assert_equal [["repos/#{Github::REPO}/commits", { per_page: 20, page: 1 }]], requested
  end

  test '/docs opens the events docs, and the Zapier and MCP pages are the integrations page' do
    covers_route 'GET /docs', 'GET /docs/:slug'
    visit '/docs'
    assert page.has_css?('h1#events', text: 'Events')
    assert page.has_current_path?('/docs/events')

    visit '/docs/mcp'
    assert page.has_css?('h1#integrations', text: 'Zapier & MCP')
    assert page.has_current_path?('/docs/integrations')

    visit '/docs/organisations'
    assert page.has_css?('h1#organisations', text: 'Organisations')
  end

  test 'someone signed in asks us a question from the docs, which emails the founder from them' do
    covers_route 'GET /docs/ask', 'POST /docs/question', 'GET /docs/question'
    account = FactoryBot.create(:account, name: 'Quinn Questioner')
    sign_in(account)
    emails = with_env('FOUNDER_EMAIL' => 'founder@example.com') do
      recorded_emails do
        visit '/docs/ask'
        assert page.has_content?('Get an answer from a human')
        fill_in 'How can we help?', with: 'How do refunds work?'
        find('button[aria-label="Send"]').click
        assert page.has_content?("Thanks for your message. We'll get back to you as soon as possible.")
      end
    end

    assert_equal 1, emails.length
    email = emails.first
    assert_equal ['founder@example.com'], email.recipients
    assert_equal '[Question] Quinn Questioner', email.subject_line
    assert_equal account.email, email.reply_to_address
    assert_includes email.text, 'How do refunds work?'
    assert_includes email.text, "/u/#{account.username}"
  end

  test 'someone signed out sees how to reach us from the docs, but no question box' do
    covers_route 'GET /docs/ask'
    visit '/docs/ask'
    assert page.has_content?('Get an answer from a human')
    assert page.has_no_field?('How can we help?')
  end

  test 'someone with an organisation sends us feedback from their home page, which emails the founder' do
    covers_route 'POST /feedback', 'GET /feedback'
    create_organisation
    @account.set(name: 'Fern Feedback')
    sign_in(@account)
    emails = with_env('FOUNDER_EMAIL' => 'founder@example.com') do
      recorded_emails do
        visit '/'
        fill_in 'Give us feedback on Dandelion', with: 'I love the new checkout'
        find('button[aria-label="Send feedback"]').click
        assert page.has_content?('Thank you for your feedback!')
      end
    end

    assert_equal 1, emails.length
    email = emails.first
    assert_equal ['founder@example.com'], email.recipients
    assert_equal '[Feedback] Fern Feedback', email.subject_line
    assert_equal @account.email, email.reply_to_address
    assert_includes email.text, 'I love the new checkout'
  end

  test 'the books and films pages list them newest first, by year' do
    covers_route 'GET /books', 'GET /films'
    LIBRARY_CACHE[:books] = [
      { slug: 'old-book', title: 'An Old Book', original_publication_year_or_year_published: '1950' },
      { slug: 'new-book', title: 'A New Book', original_publication_year_or_year_published: '2021' }
    ]
    LIBRARY_CACHE[:films] = [
      { slug: 'old-film', name: 'An Old Film', year: '1982', url: 'https://example.com/old-film' },
      { slug: 'new-film', name: 'A New Film', year: '2019', url: 'https://example.com/new-film' }
    ]

    visit '/books'
    assert page.has_content?('Books recommended by the Dandelion team')
    assert_equal ['2021', 'Before 1969'], all('h2.mt-5').map(&:text)
    assert_equal(['A New Book', 'An Old Book'], all('a[href^="/books/"] img').map { |img| img[:alt] })

    visit '/films'
    assert page.has_content?('Films recommended by the Dandelion team')
    assert_equal ['2019', 'Before 1989'], all('h2.mt-5').map(&:text)
    assert page.has_css?('a[href="https://example.com/new-film"] img[alt="A New Film"]')
  ensure
    LIBRARY_CACHE.delete(:books)
    LIBRARY_CACHE.delete(:films)
  end

  test "a location's page counts and lists the public events near it, not secret ones" do
    covers_route 'GET /locations/:name'
    Location.create!(name: 'Stockholm', query: 'Stockholm')
    create_event(name: 'Midsummer Dance', prices: [0])
    create_event(name: 'Secret Supper', prices: [0], secret: true, as: :secret_event)

    visit '/locations/Stockholm'
    assert page.has_content?('Check out 1 upcoming event near Stockholm on Dandelion')
    assert page.has_link?('Midsummer Dance')
    assert page.has_no_content?('Secret Supper')

    visit '/locations/Nowhere'
    assert page.has_content?("Hmm, we couldn't find that page.")
  end

  test 'recommended people are those someone went to events with, leaving out private profiles' do
    covers_route 'GET /recommendations/people'
    create_event(name: 'Breathwork Circle', start_time: 2.weeks.ago, end_time: 2.weeks.ago + 2.hours, prices: [0])
    alice = FactoryBot.create(:account, name: 'Alice Attendee', has_signed_in: true)
    bob = FactoryBot.create(:account, name: 'Bob Attendee', has_signed_in: true)
    hidden = FactoryBot.create(:account, name: 'Hana Hidden', has_signed_in: true, hidden: true)
    [alice, bob, hidden].each { |account| @event.tickets.create!(account: account, ticket_type: @event.ticket_types.first, payment_completed: true) }

    sign_in(alice)
    visit '/recommendations/people'
    assert page.has_link?('Bob Attendee', href: "/u/#{bob.username}")
    assert page.has_link?('Breathwork Circle')
    assert page.has_no_content?('Hana Hidden')
  end

  test "recommended events are public ones the people someone went to events with are going to" do
    covers_route 'GET /recommendations/events'
    create_event(name: 'Breathwork Circle', start_time: 2.weeks.ago, end_time: 2.weeks.ago + 2.hours, prices: [0])
    create_event(name: 'Sound Bath', prices: [0], as: :future_event)
    create_event(name: 'Secret Sound Bath', prices: [0], secret: true, as: :secret_event)
    alice = FactoryBot.create(:account, name: 'Alice Attendee', has_signed_in: true)
    bob = FactoryBot.create(:account, name: 'Bob Attendee', has_signed_in: true)
    [alice, bob].each { |account| @event.tickets.create!(account: account, ticket_type: @event.ticket_types.first, payment_completed: true) }
    [@future_event, @secret_event].each { |event| event.tickets.create!(account: bob, ticket_type: event.ticket_types.first, payment_completed: true) }

    sign_in(alice)
    visit '/recommendations/events'
    assert page.has_link?('Sound Bath', href: "/e/#{@future_event.slug}")
    assert page.has_no_content?('Secret Sound Bath')
  end

  test 'a referrer claims the reward for an organisation that has given enough to Dandelion, once' do
    covers_route 'GET /referrals', 'POST /referrals/:id/claim'
    admin = FactoryBot.create(:account, admin: true)
    referrer = FactoryBot.create(:account, name: 'Rita Referrer')
    create_organisation(name: 'Thriving Collective', referrer: referrer)
    @organisation.organisation_contributions.create!(amount: 200, currency: 'EUR', payment_completed: true)
    other = FactoryBot.create(:organisation, name: 'Fledgling Collective', referrer: referrer)

    sign_in(referrer)
    emails = recorded_emails do
      visit '/referrals'
      assert page.has_link?('Fledgling Collective')
      within(:xpath, "//div[contains(@class, 'card-body')][.//a[normalize-space()='Thriving Collective']]") { click_link 'Claim reward' }
      assert page.has_content?("Your referral reward claim has been submitted, and we'll be in touch soon.")
    end

    assert_equal 1, emails.length
    assert_equal [admin.email], emails.first.recipients
    assert_equal '[Reward claim] Rita Referrer for Thriving Collective', emails.first.subject_line
    assert_equal referrer.id, @organisation.reload.reward_claimer_id
    assert_nil other.reload.reward_claimer_id
    within(:xpath, "//div[contains(@class, 'card-body')][.//a[normalize-space()='Thriving Collective']]") { assert page.has_button?('Claimed', disabled: true) }
    assert page.has_no_link?('Claim reward')
  end

  test 'collapsing the sidebar keeps it collapsed on the next page' do
    covers_route 'POST /sidebar'
    sign_in(FactoryBot.create(:account))
    visit '/contact'
    assert page.has_css?('#page-container:not(.page-sidebar-minified)')
    find('button[aria-label="Collapse or expand the sidebar"]').click
    assert page.has_css?('#page-container.page-sidebar-minified')
    # The page posts to /sidebar as it collapses: let that finish before leaving it
    Timeout.timeout(5) { sleep 0.05 until evaluate_script('jQuery.active').zero? }

    visit '/privacy'
    assert page.has_content?('Privacy Policy')
    assert page.has_css?('#page-container.page-sidebar-minified')
  end
end
