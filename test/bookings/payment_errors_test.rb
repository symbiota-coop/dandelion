require_relative '../test_config'
require_relative '../helpers/bookings_helpers'

# What a payment provider's error on a booking does: one caused by what the buyer entered fails only their purchase,
# while one that means no one can buy tickets locks the event (OrderBuilder#call, EventPaymentMethod.purchase_error_for)
class BookingPaymentErrorsTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include BookingsHelpers

  # Stripe Checkout as far as creating a session: it refuses metadata over its limits, as Stripe does, or raises error
  def with_fake_stripe(sessions = [], error: nil, &)
    create = lambda do |params, _opts|
      sessions << params
      raise error if error

      [params[:metadata], params[:payment_intent_data][:metadata]].each do |metadata|
        metadata.each do |key, value|
          raise Stripe::InvalidRequestError.new('Invalid metadata: keys must be at most 40 characters', "metadata[#{key}]") if key.to_s.length > 40
          raise Stripe::InvalidRequestError.new('Invalid metadata: values must be at most 500 characters', "metadata[#{key}]") if value.to_s.length > 500
        end
      end
      api_object(id: 'cs_test', payment_intent: 'pi_test', url: 'https://checkout.stripe.com/test')
    end
    Stripe::Checkout::Session.stub(:create, create, &)
  end

  def create_stripe_checkout_event
    create_organisation(stripe_sk: 'sk_test_organisation')
    create_event(prices: [10])
    assert EventPaymentMethod.object('stripe').available?(@event)
  end

  test 'a buyer whose name and answers are over Stripe\'s metadata limits can still pay, and the event stays open' do
    covers 'events/buyer-error-does-not-lock-event@b1a837'
    covers_route 'POST /e/:slug/purchase'
    create_stripe_checkout_event
    question = 'What extraordinarily particular dietary requirements might you have'
    @event.update_attributes!(questions: question)
    @organisation.set(event_questions_to_include_in_metadata: [question])
    buyer = FactoryBot.create(:account, name: 'n' * 600)

    sessions = []
    with_fake_stripe(sessions) do
      post_purchase(@event, buyer, payment_method: 'stripe', details_form: { answers: { '0' => 'a' * 600 }, utm_campaign: 'c' * 6000 })
    end

    assert_equal 200, last_response.status
    assert_equal 'cs_test', JSON.parse(last_response.body)['session_id']
    metadata = sessions.last[:metadata]
    assert_equal 'n' * 500, metadata[:de_account_name]
    assert_equal ['a' * 500], metadata.select { |key, _| key.to_s.start_with?('de_question_') }.values
    assert sessions.last[:success_url].end_with?("&utm_campaign=#{'c' * OrderBuilder::UTM_MAX_LENGTH}")
    assert_equal 1, @event.orders.count
    assert_equal false, @event.reload.locked?
  end

  test 'answers to two questions whose metadata keys cut to the same 40 characters both reach Stripe' do
    create_stripe_checkout_event
    questions = ['Accessibility requirements for wheelchair users', 'Accessibility requirements for the hearing loop']
    @event.update_attributes!(questions: questions.join("\n"))
    @organisation.set(event_questions_to_include_in_metadata: questions)

    sessions = []
    with_fake_stripe(sessions) do
      post_purchase(@event, payment_method: 'stripe', details_form: { answers: { '0' => 'wheelchair user', '1' => 'hearing loop' } })
    end

    assert_equal 200, last_response.status
    [sessions.last[:metadata], sessions.last[:payment_intent_data][:metadata]].each do |metadata|
      answers = metadata.select { |key, _| key.to_s.start_with?('de_question_') }
      assert_equal({ de_question_accessibility_requirements_f: 'wheelchair user', de_question_accessibility_requirements_2: 'hearing loop' }, answers)
    end
  end

  test 'Stripe refusing a value the buyer entered fails only their purchase' do
    covers 'events/buyer-error-does-not-lock-event@b1a837'
    create_stripe_checkout_event
    error = Stripe::InvalidRequestError.new('Invalid value for metadata: values must be at most 500 characters', 'metadata[de_account_name]')

    emails = recorded_emails do
      with_fake_stripe(error: error) { post_purchase(@event, payment_method: 'stripe') }
    end

    assert_equal 400, last_response.status
    assert_equal false, @event.reload.locked?
    assert_nil @event.locked_error
    assert_equal 0, @event.orders.count
    assert_equal ["Stripe error on #{@event.name}"], emails.map(&:subject_line).grep(/error/)

    with_fake_stripe { post_purchase(@event, payment_method: 'stripe') }
    assert_equal 200, last_response.status
  end

  test 'Stripe refusing the organisation\'s account locks the event' do
    covers 'events/payment-error-locks-event@a6adde'
    [
      Stripe::InvalidRequestError.new("No such destination: 'acct_gone'", 'payment_intent_data[transfer_data][destination]', code: 'resource_missing'),
      Stripe::InvalidRequestError.new('Your account cannot currently make live charges.', nil)
    ].each do |error|
      create_stripe_checkout_event
      with_fake_stripe(error: error) { post_purchase(@event, payment_method: 'stripe') }

      assert_equal 400, last_response.status
      assert_equal true, @event.reload.locked?, error.class.name
      assert_equal error.message, @event.locked_error
      assert_equal 'Stripe', @event.locked_error_provider
      assert_equal(1, queued_jobs(:delete_atproto, on: Event).count { |job| job.payload_object.object.id == @event.id })
    end
  end
end
