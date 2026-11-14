require_relative '../test_config'

# Setting up the Stripe webhook endpoint (StripeWebhooks) that completes an organisation's or a gathering's ticket
# orders, on their own Stripe account, whenever one with a Stripe secret key is saved in production
class PaymentsStripeWebhooksTest < ActiveSupport::TestCase
  include Capybara::DSL

  OTHER_URL = 'https://example.com/other_webhook'.freeze

  # Stubs Stripe::WebhookEndpoint, listing these pages of endpoints (each a list of attribute hashes), and records each
  # call's arguments in calls[:list], calls[:create] and calls[:update]. Raises error from every call if given
  def stub_webhook_endpoints(pages: [[]], error: nil, secret: 'whsec_new', &)
    calls = { list: [], create: [], update: [] }
    list = lambda do |params, opts|
      calls[:list] << [params, opts]
      raise error if error

      index = calls[:list].length - 1
      data = pages.fetch(index).map { |attributes| Stripe::StripeObject.construct_from(attributes) }
      api_object(data: data, has_more: index < pages.length - 1)
    end
    create = lambda do |params, opts|
      calls[:create] << [params, opts]
      Stripe::StripeObject.construct_from(id: 'we_new', secret: secret)
    end
    update = ->(id, params, opts) { calls[:update] << [id, params, opts] }
    Stripe::WebhookEndpoint.stub(:list, list) do
      Stripe::WebhookEndpoint.stub(:create, create) do
        Stripe::WebhookEndpoint.stub(:update, update) do
          yield calls
        end
      end
    end
  end

  def in_production(&)
    Padrino.stub(:env, :production, &)
  end

  def stripe_organisation
    create_organisation(stripe_sk: 'sk_live_org', stripe_pk: 'pk_live_org')
  end

  def endpoint(id, url, enabled_events)
    { id: id, url: url, enabled_events: enabled_events }
  end

  test 'an organisation with no endpoint for its webhook URL gets one for paid checkouts, on its own key, and saves its secret' do
    organisation = stripe_organisation
    stub_webhook_endpoints(pages: [[endpoint('we_other', OTHER_URL, ['*'])]]) do |calls|
      in_production { organisation.create_stripe_webhook_if_necessary }

      assert_equal 'sk_live_org', calls[:list].first.last[:api_key]
      assert_equal 1, calls[:create].length
      params, opts = calls[:create].first
      assert_equal({ url: organisation.stripe_webhook_url, enabled_events: StripeCheckout::PAID_EVENT_TYPES }, params)
      assert_equal 'sk_live_org', opts[:api_key]
      assert_empty calls[:update]
    end
    assert_equal 'whsec_new', organisation.reload.stripe_endpoint_secret
  end

  test 'an existing endpoint missing paid event types gets them added, keeping its others, and none is created' do
    organisation = stripe_organisation
    events = ['charge.refunded', StripeCheckout::PAID_EVENT_TYPES.first]
    stub_webhook_endpoints(pages: [[endpoint('we_org', organisation.stripe_webhook_url, events)]]) do |calls|
      in_production { organisation.create_stripe_webhook_if_necessary }

      assert_equal 1, calls[:update].length
      id, params, opts = calls[:update].first
      assert_equal 'we_org', id
      assert_equal(['charge.refunded'] + StripeCheckout::PAID_EVENT_TYPES, params[:enabled_events])
      assert_equal 'sk_live_org', opts[:api_key]
      assert_empty calls[:create]
    end
    assert_nil organisation.reload.stripe_endpoint_secret
  end

  test 'an existing endpoint that has every paid event type, or all events, is left alone' do
    organisation = stripe_organisation
    [StripeCheckout::PAID_EVENT_TYPES + ['charge.refunded'], ['*']].each do |events|
      stub_webhook_endpoints(pages: [[endpoint('we_org', organisation.stripe_webhook_url, events)]]) do |calls|
        in_production { organisation.create_stripe_webhook_if_necessary }

        assert_equal 1, calls[:list].length
        assert_empty calls[:update], "updated an endpoint with #{events}"
        assert_empty calls[:create], "created an endpoint beside one with #{events}"
      end
    end
  end

  test 'the endpoints are listed page by page, so one on a later page is found' do
    organisation = stripe_organisation
    pages = [
      [endpoint('we_1', OTHER_URL, ['*']), endpoint('we_2', OTHER_URL, ['*'])],
      [endpoint('we_3', OTHER_URL, ['*'])],
      [endpoint('we_org', organisation.stripe_webhook_url, StripeCheckout::PAID_EVENT_TYPES)]
    ]
    stub_webhook_endpoints(pages: pages) do |calls|
      in_production { organisation.create_stripe_webhook_if_necessary }

      assert_equal([nil, 'we_2', 'we_3'], calls[:list].map { |params, _opts| params[:starting_after] })
      assert(calls[:list].all? { |params, _opts| params[:limit] == 100 })
      assert_empty calls[:create]
      assert_empty calls[:update]
    end
  end

  test 'a Stripe key Stripe refuses is removed' do
    organisation = stripe_organisation
    stub_webhook_endpoints(error: Stripe::AuthenticationError.new('Invalid API Key provided')) do |calls|
      in_production { organisation.create_stripe_webhook_if_necessary }

      assert_empty calls[:create]
    end
    organisation.reload
    assert_nil organisation.stripe_sk
    assert_nil organisation.stripe_pk
  end

  test 'outside production nothing calls Stripe' do
    organisation = stripe_organisation
    stub_webhook_endpoints do |calls|
      organisation.create_stripe_webhook_if_necessary
      organisation.update_attributes!(name: 'Renamed')

      assert_empty calls.values.flatten
    end
    assert_nil organisation.reload.stripe_endpoint_secret
  end

  test 'saving an organisation sets up its webhook only when it has a Stripe secret key' do
    organisation = create_organisation(stripe_sk: nil, stripe_pk: nil)
    stub_webhook_endpoints do |calls|
      in_production { organisation.update_attributes!(name: 'Renamed') }
      assert_empty calls[:list]

      in_production { organisation.update_attributes!(stripe_sk: 'sk_live_org', stripe_pk: 'pk_live_org') }
      assert_equal 1, calls[:create].length
      assert_equal organisation.stripe_webhook_url, calls[:create].first.first[:url]
    end
    assert_equal 'whsec_new', organisation.reload.stripe_endpoint_secret
  end

  test 'saving a gathering with a Stripe secret key sets up its own webhook' do
    gathering = FactoryBot.create(:gathering, account: FactoryBot.create(:account), stripe_sk: nil, stripe_pk: nil)
    stub_webhook_endpoints(secret: 'whsec_gathering') do |calls|
      in_production { gathering.update_attributes!(stripe_sk: 'sk_live_gathering', stripe_pk: 'pk_live_gathering') }

      assert_equal 1, calls[:create].length
      params, opts = calls[:create].first
      assert_equal "#{ENV['BASE_URI']}/g/#{gathering.slug}/stripe_webhook", params[:url]
      assert_equal 'sk_live_gathering', opts[:api_key]
    end
    assert_equal 'whsec_gathering', gathering.reload.stripe_endpoint_secret
  end

  test "an admin saving an organisation's Stripe keys sets up its webhook" do
    covers_route 'POST /o/:slug/edit'
    create_organisation(stripe_sk: nil, stripe_pk: nil)
    @organisation.set(experimental: true)
    create_event
    sign_in @account
    visit "/o/#{@organisation.slug}/edit"
    click_on 'Experimental'
    fill_in 'Stripe public key', with: 'pk_live_form'
    fill_in 'Stripe secret key', with: 'sk_live_form'

    stub_webhook_endpoints(secret: 'whsec_form') do |calls|
      in_production do
        click_on 'Update organisation'
        assert page.has_content?('The organisation was saved')
      end

      assert_equal 1, calls[:create].length
      params, opts = calls[:create].first
      assert_equal @organisation.stripe_webhook_url, params[:url]
      assert_equal 'sk_live_form', opts[:api_key]
    end
    assert_equal 'whsec_form', @organisation.reload.stripe_endpoint_secret
  end
end
