require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class AnalyticsProvidersTest < ActiveSupport::TestCase
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

  test 'plausible is enabled by organisation domain' do
    create_organisation
    provider = AnalyticsProvider.object('plausible')
    refute provider.enabled?(organisation: @organisation)
    @organisation.plausible_analytics_domain = 'soulrev.plausible.io'
    assert provider.enabled?(organisation: @organisation)
  end

  test 'simple analytics is enabled by organisation domain' do
    create_organisation
    provider = AnalyticsProvider.object('simple_analytics')
    refute provider.enabled?(organisation: @organisation)
    @organisation.simple_analytics_domain = 'soulrev.simpleanalytics.com'
    assert provider.enabled?(organisation: @organisation)
  end

  test 'facebook pixel strips blanks and rejects non-numeric ids' do
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
    create_organisation
    @organisation.google_ads_conversion_label = 'Purchase'
    refute @organisation.valid?
    assert @organisation.errors[:google_ads_conversion_id].any?

    @organisation.assign_attributes(google_ads_conversion_id: '6782912626', google_ads_conversion_label: nil)
    refute @organisation.valid?
    assert @organisation.errors[:google_ads_conversion_label].any?
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
    create_organisation
    sign_in_with_rack(@account)
    post "/o/#{@organisation.slug}/edit", organisation: {
      plausible_analytics_domain: 'soulrev.plausible.io',
      simple_analytics_domain: 'soulrev.simpleanalytics.com',
      facebook_pixel_id: '1234567890',
      google_ads_conversion_id: 'AW-6782912626',
      google_ads_conversion_label: 'Purchase',
      google_ads_enhanced_conversions: '1'
    }
    follow_redirect! while last_response.redirect?
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
end
