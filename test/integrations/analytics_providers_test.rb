require_relative '../test_config'

class AnalyticsProvidersTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  test 'registry lists providers and marketing cookies' do
    assert_equal %w[plausible simple_analytics facebook google_ads], AnalyticsProvider.all.map(&:name)
    assert AnalyticsProvider.object('facebook').applies_to?(Event)
    assert AnalyticsProvider.object('google_ads').applies_to?(Event)
    refute AnalyticsProvider.object('plausible').applies_to?(Event)
    refute AnalyticsProvider.object('simple_analytics').applies_to?(Event)
    assert_includes AnalyticsProvider.expire_cookies_for(:marketing), '_gcl_aw'
    assert_includes AnalyticsProvider.expire_cookies_for(:marketing), '_fbp'
  end

  test 'facebook pixel strips blanks and rejects non-numeric ids' do
    covers 'organisations/analytics-ids@905e12'
    create_organisation
    @organisation.facebook_pixel_id = ' 1234567890 '
    assert @organisation.valid?
    assert_equal '1234567890', @organisation.facebook_pixel_id

    @organisation.facebook_pixel_id = '   '
    assert @organisation.valid?
    assert_nil @organisation.facebook_pixel_id

    @organisation.facebook_pixel_id = 'not-a-pixel'
    refute @organisation.valid?
    assert @organisation.errors[:facebook_pixel_id].any?
  end

  test 'facebook is enabled by organisation or event pixel' do
    covers 'organisations/analytics-org-and-event-both-sent@6bdbdc'
    create_event
    provider = AnalyticsProvider.object('facebook')
    refute provider.enabled?(organisation: @organisation, event: @event)

    @organisation.facebook_pixel_id = '1111111111'
    assert provider.enabled?(organisation: @organisation, event: @event)

    @organisation.facebook_pixel_id = nil
    @event.facebook_pixel_id = '2222222222'
    assert provider.enabled?(organisation: @organisation, event: @event)
  end

  test 'facebook pixel ids are unique across organisation and event' do
    covers 'organisations/analytics-org-and-event-both-sent@6bdbdc'
    create_event
    @organisation.facebook_pixel_id = '1111111111'
    @event.facebook_pixel_id = '1111111111'
    assert_equal %w[1111111111], AnalyticsProvider.facebook_pixel_ids(organisation: @organisation, event: @event)

    @event.facebook_pixel_id = '2222222222'
    assert_equal %w[1111111111 2222222222], AnalyticsProvider.facebook_pixel_ids(organisation: @organisation, event: @event)
  end

  test 'event duplication copies facebook pixel id' do
    create_event
    @event.update!(facebook_pixel_id: '1234567890')
    duplicate = @event.duplicate!(@account)
    assert_equal '1234567890', duplicate.facebook_pixel_id
  end

  test 'normalises AW- prefix, strips blanks and accepts a purchase label' do
    create_organisation
    @organisation.assign_attributes(
      google_ads_conversion_id: ' AW-6782912626 ',
      google_ads_conversion_label: ' Purchase ',
      google_ads_enhanced_conversions: true
    )
    assert @organisation.valid?
    assert_equal '6782912626', @organisation.google_ads_conversion_id
    assert_equal 'Purchase', @organisation.google_ads_conversion_label
    assert_equal(
      { id: '6782912626', label: 'Purchase', enhanced: true },
      @organisation.google_ads_conversion
    )
  end

  test 'google ads conversion requires both id and label' do
    covers 'organisations/analytics-ids@905e12'
    create_organisation
    @organisation.google_ads_conversion_label = 'Purchase'
    refute @organisation.valid?
    assert @organisation.errors[:google_ads_conversion_id].any?

    @organisation.assign_attributes(google_ads_conversion_id: '6782912626', google_ads_conversion_label: nil)
    refute @organisation.valid?
    assert @organisation.errors[:google_ads_conversion_label].any?
    refute AnalyticsProvider.object('google_ads').enabled?(organisation: @organisation)
    assert_empty AnalyticsProvider.google_ads_conversions(organisation: @organisation)
  end

  test 'event edit with a conversion id but no label re-renders' do
    create_event
    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    click_link 'Integrations'
    fill_in 'Google Ads conversion ID', with: '6782912626'
    click_button 'Update event'
    assert page.has_content? 'There was an error saving the event.'
    assert page.has_button? 'Update event'
    assert_nil @event.reload.google_ads_conversion_id
  end

  test 'clears blank google ads fields' do
    create_organisation
    @organisation.assign_attributes(
      google_ads_conversion_id: '   ',
      google_ads_conversion_label: '   '
    )
    assert @organisation.valid?
    assert_nil @organisation.google_ads_conversion_id
    assert_nil @organisation.google_ads_conversion_label
    assert_nil @organisation.google_ads_conversion
  end

  test 'rejects a non-numeric conversion id' do
    create_organisation
    @organisation.google_ads_conversion_id = 'not-an-id'
    refute @organisation.valid?
    assert @organisation.errors[:google_ads_conversion_id].any?
  end

  test 'rejects a conversion label with spaces' do
    create_organisation
    @organisation.google_ads_conversion_label = 'Purchase conversion'
    refute @organisation.valid?
    assert @organisation.errors[:google_ads_conversion_label].any?
  end

  test 'event duplication copies google ads fields' do
    create_event
    @event.update!(
      google_ads_conversion_id: '6782912626',
      google_ads_conversion_label: 'Purchase',
      google_ads_enhanced_conversions: true
    )
    duplicate = @event.duplicate!(@account)
    assert_equal '6782912626', duplicate.google_ads_conversion_id
    assert_equal 'Purchase', duplicate.google_ads_conversion_label
    assert duplicate.google_ads_enhanced_conversions
  end

  test 'google ads conversions are unique across organisation and event' do
    covers 'organisations/analytics-org-and-event-both-sent@6bdbdc'
    create_event
    @organisation.update!(
      google_ads_conversion_id: '6782912626',
      google_ads_conversion_label: 'Purchase',
      google_ads_enhanced_conversions: true
    )
    @event.update!(
      google_ads_conversion_id: '6782912626',
      google_ads_conversion_label: 'Purchase'
    )

    conversions = AnalyticsProvider.google_ads_conversions(organisation: @organisation, event: @event)
    assert_equal [{ id: '6782912626', label: 'Purchase', enhanced: true }], conversions
    assert(conversions.any? { |conversion| conversion[:enhanced] })
  end

  test 'organisation edit saves analytics provider fields' do
    covers 'organisations/analytics-ids@905e12'
    create_organisation
    refute AnalyticsProvider.object('plausible').enabled?(organisation: @organisation)
    refute AnalyticsProvider.object('simple_analytics').enabled?(organisation: @organisation)
    sign_in(@account)
    visit "/o/#{@organisation.slug}/edit"
    click_link 'Analytics'
    fill_in 'Plausible Analytics domain', with: 'soulrev.plausible.io'
    fill_in 'Simple Analytics domain', with: 'soulrev.simpleanalytics.com'
    fill_in 'Facebook Pixel ID', with: '1234567890'
    fill_in 'Google Ads conversion ID', with: 'AW-6782912626'
    fill_in 'Google Ads conversion label', with: 'Purchase'
    find('label[for="organisation_google_ads_enhanced_conversions"]').click
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    @organisation.reload
    assert_equal 'soulrev.plausible.io', @organisation.plausible_analytics_domain
    assert_equal 'soulrev.simpleanalytics.com', @organisation.simple_analytics_domain
    assert_equal '1234567890', @organisation.facebook_pixel_id
    assert_equal '6782912626', @organisation.google_ads_conversion_id
    assert_equal 'Purchase', @organisation.google_ads_conversion_label
    assert @organisation.google_ads_enhanced_conversions?
    assert AnalyticsProvider.object('plausible').enabled?(organisation: @organisation)
    assert AnalyticsProvider.object('simple_analytics').enabled?(organisation: @organisation)
    assert AnalyticsProvider.object('facebook').enabled?(organisation: @organisation)
    assert AnalyticsProvider.object('google_ads').enabled?(organisation: @organisation)
  end

  # The analytics partials render only in production (layouts/_head.erb)
  def get_in_production(path)
    Padrino.stub(:env, :production) { get path }
    assert last_response.ok?, last_response.status.to_s
    Nokogiri::HTML(last_response.body)
  end

  # The marketing scripts on a page, which cookie_consent.js runs only once marketing cookies are allowed
  def marketing_scripts(doc)
    doc.css('script[data-cookie-category="marketing"]')
  end

  # The values the partials pass to their script's (function (x) { ... })(<json>) calls
  def script_arguments(script)
    script.text.scan(/^\s*\}\)\((.*)\);$/).map { |(json)| JSON.parse(json) }
  end

  def create_event_with_analytics
    create_event(prices: [10])
    @organisation.update!(facebook_pixel_id: '1234567890', google_ads_conversion_id: '6782912626', google_ads_conversion_label: 'Purchase', google_ads_enhanced_conversions: true)
  end

  def create_paid_order
    buyer = FactoryBot.create(:account, phone: '+447700900123')
    @order = @event.orders.create!(account: buyer, currency: 'GBP', value: 10, payment_completed: true)
    @order.tickets.create!(event: @event, account: buyer, ticket_type: @event.ticket_types.first)
  end

  test 'pixel and google ads tags load on organisation and event pages, held back until marketing cookie consent' do
    covers 'organisations/analytics-tags-need-marketing-consent@3bd32f', 'organisations/google-ads-conversion@d1d9d3'
    create_event_with_analytics

    ["/o/#{@organisation.slug}", "/e/#{@event.slug}"].each do |path|
      doc = get_in_production(path)
      scripts = marketing_scripts(doc)
      # Held as text/plain until marketing consent, so the browser doesn't run them
      assert(scripts.all? { |script| script['type'] == 'text/plain' }, path)
      assert(scripts.any? { |script| script.text.include?("fbq('init', pixelId)") && script.text.include?('["1234567890"]') }, path)
      assert(scripts.any? { |script| script['src'] == 'https://www.googletagmanager.com/gtag/js?id=AW-6782912626' }, path)
      assert(scripts.any? { |script| script.text.include?('"id":"AW-6782912626"') }, path)
      # Nothing runs the tags without consent
      refute(doc.css('script').reject { |script| script['type'] == 'text/plain' }.any? { |script| script.text.include?('fbevents.js') || script.text.include?("gtag('config'") }, path)
      refute(doc.css('script[src*="googletagmanager"]').any? { |script| script['type'] != 'text/plain' }, path)
    end
  end

  test 'meta pixel tracks PageView and ViewContent on event pages, and a single Purchase after booking' do
    covers 'organisations/meta-pixel-events@594c53', 'events/purchase-conversions-on-thank-you-page@3746ce'
    create_event_with_analytics

    pixel = marketing_scripts(get_in_production("/e/#{@event.slug}")).find { |script| script.text.include?('fbq(') }
    assert_includes pixel.text, "fbq('track', 'PageView')"
    view_content, purchase = script_arguments(pixel)
    assert_equal({ 'content_name' => @event.name, 'content_ids' => [@event.id.to_s], 'content_type' => 'product' }, view_content)
    assert_nil purchase

    create_paid_order
    pixel = marketing_scripts(get_in_production("/e/#{@event.slug}?order_id=#{@order.token}&success=true")).find { |script| script.text.include?('fbq(') }
    assert_includes pixel.text, "fbq('track', 'PageView')"
    view_content, purchase = script_arguments(pixel)
    assert_nil view_content
    assert_equal @order.id.to_s, purchase['order_id']
    assert_equal({ 'currency' => 'GBP', 'value' => 10.0, 'content_type' => 'product', 'content_ids' => [@event.ticket_types.first.id.to_s],
                   'content_name' => @event.name, 'num_items' => 1 }, purchase['params'])
    # Sent once per order: the order ID dedupes it with Meta, and the page skips it if it has already sent it
    assert_includes pixel.text, "fbq('track', 'Purchase', purchase.params, {eventID: orderId})"
    assert_includes pixel.text, "sessionStorage.getItem(storageKey)) return"
  end

  test 'google ads fires a single conversion with value, currency and order ID, with hashed user data for enhanced conversions' do
    covers 'organisations/google-ads-conversion@d1d9d3', 'organisations/google-ads-enhanced-conversions@fbfbbf', 'events/purchase-conversions-on-thank-you-page@3746ce'
    create_event_with_analytics

    gtag = marketing_scripts(get_in_production("/e/#{@event.slug}")).find { |script| script.text.include?('gtag(') }
    assert_equal [nil], script_arguments(gtag)

    create_paid_order
    gtag = marketing_scripts(get_in_production("/e/#{@event.slug}?order_id=#{@order.token}&success=true")).find { |script| script.text.include?('gtag(') }
    purchase = script_arguments(gtag).first
    assert_equal({ 'value' => 10.0, 'currency' => 'GBP', 'transaction_id' => @order.id.to_s }, purchase['params'])
    assert_equal ['AW-6782912626/Purchase'], purchase['send_to']
    assert_includes gtag.text, "sessionStorage.getItem(storageKey)) return"
    # gtag.js normalises and hashes user_data before sending it (allow_enhanced_conversions)
    # Anyone with the order's link sees this page, so the account's phone goes only to the account itself
    assert_equal({ 'email' => @order.account.email }, purchase['user_data'])
    env 'rack.session', { 'account_id' => @order.account.id.to_s, 'session_token' => @order.account.session_token! }
    gtag = marketing_scripts(get_in_production("/e/#{@event.slug}?order_id=#{@order.token}&success=true")).find { |script| script.text.include?('gtag(') }
    assert_equal({ 'email' => @order.account.email, 'phone_number' => '+447700900123' }, script_arguments(gtag).first['user_data'])
    env 'rack.session', {}
    assert_includes gtag.text, "gtag('set', 'user_data', purchase.user_data)"
    assert_includes gtag.text, "gtag('config', config.id, {allow_enhanced_conversions: true})"

    @organisation.update!(google_ads_enhanced_conversions: false)
    gtag = marketing_scripts(get_in_production("/e/#{@event.slug}?order_id=#{@order.token}&success=true")).find { |script| script.text.include?('gtag(') }
    purchase = script_arguments(gtag).first
    assert_equal @order.id.to_s, purchase['order_id']
    assert_nil purchase['user_data']
  end
end
