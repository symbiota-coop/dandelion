require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# What reaches Sentry with an error (config/sentry_config.rb)
class SentryTest < ActiveSupport::TestCase
  def error_event_for(env)
    event = Sentry::ErrorEvent.new(configuration: Sentry.configuration)
    event.rack_env = env
    event
  end

  def form_post(params, query: '')
    Rack::MockRequest.env_for("/o/an-org/edit?#{query}", method: 'POST', params: params)
  end

  def before_send(event)
    Sentry.configuration.before_send.call(event, { exception: RuntimeError.new('boom') })
  end

  test 'nested payment and email keys in a form are filtered' do
    env = form_post({ 'organisation' => { 'name' => 'An org', 'stripe_sk' => 'sk_live_1', 'stripe_pk' => 'pk_live_1',
                                          'mailgun_api_key' => 'mg', 'mollie_api_key' => 'mo',
                                          'paypal_secret' => 'pp', 'gocardless_access_token' => 'gc' },
                      'gathering' => { 'stripe_sk' => 'sk_live_2' } })
    data = before_send(error_event_for(env)).request.data

    organisation = data['organisation']
    %w[stripe_sk mailgun_api_key mollie_api_key paypal_secret gocardless_access_token].each do |key|
      assert_equal '[Filtered]', organisation[key], key
    end
    assert_equal '[Filtered]', data['gathering']['stripe_sk']
    assert_equal 'An org', organisation['name']
    assert_equal 'pk_live_1', organisation['stripe_pk']
  end

  test 'top-level stripe_sk and nested query keys are filtered' do
    event = before_send(error_event_for(form_post({ 'stripe_sk' => 'sk_live_1', 'name' => 'x' },
                                                  query: 'organisation[mailgun_api_key]=mg&page=2')))

    assert_equal '[Filtered]', event.request.data['stripe_sk']
    assert_equal 'x', event.request.data['name']
    assert_equal '[Filtered]', event.request.query_string['organisation']['mailgun_api_key']
    assert_equal '2', event.request.query_string['page']
  end

  test 'a sign in code in the query is filtered' do
    event = before_send(error_event_for(Rack::MockRequest.env_for('/events?sign_in_code=abc123&account%5Bpostcode%5D=N1')))

    assert_equal '[Filtered]', event.request.query_string['sign_in_code']
    assert_equal 'N1', event.request.query_string['account']['postcode']
  end
end
