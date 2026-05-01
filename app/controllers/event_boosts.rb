Dandelion::App.controller do
  get '/events/:id/boosts' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!

    @event_boosts = @event.event_boosts.and(:payment_completed => true).order('created_at desc')
    currency = @event.currency_or_default
    @min_hourly_boost = EventBoost.minimum_hourly_amount(currency)

    @event_boost = @event.event_boosts.build(
      account: current_account,
      start_time: Time.zone.now.beginning_of_hour + 1.hour,
      hours: 1,
      hourly_amount: @min_hourly_boost,
      currency: currency
    )

    slot_starts = []
    @event.event_boosts.and(:payment_completed => true).each do |boost|
      t = boost.start_time.beginning_of_hour
      while t < boost.end_time
        slot_starts << t
        t += 1.hour
      end
    end
    @paid_boost_hour_slots = slot_starts.uniq.sort.map do |slot_start|
      EventBoost.pool_hour_stats(@event, slot_start: slot_start)
    end

    erb :'event_boosts/boosts'
  end

  post '/events/:id/boosts', provides: :json do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!

    @event_boost = @event.event_boosts.new(
      mass_assigning(params[:event_boost], EventBoost).merge(account: current_account)
    )

    halt 400, { error: @event_boost.errors.full_messages.first }.to_json unless @event_boost.save

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = ENV['STRIPE_API_VERSION']

    session = Stripe::Checkout::Session.create({
                                                 customer_email: current_account.email,
                                                 success_url: "#{ENV['BASE_URI']}/events/#{@event.id}/boosts?thanks=1",
                                                 cancel_url: "#{ENV['BASE_URI']}/events/#{@event.id}/boosts?cancelled=1",
                                                 line_items: [{
                                                   name: "Event boost for #{@event.name}",
                                                   description: "#{@event_boost.hours}h at #{Money.new((@event_boost.hourly_amount * 100).round, @event_boost.currency).format(no_cents_if_whole: true)}/h, starting #{@event_boost.start_time}",
                                                   amount: (@event_boost.total_amount * 100).round,
                                                   currency: @event_boost.currency,
                                                   quantity: 1
                                                 }]
                                               })

    @event_boost.update_attributes!(session_id: session.id, payment_intent: session.payment_intent)

    { session_id: session.id }.to_json
  rescue StandardError => e
    ErrorTracking.notify(e)
    @event_boost.destroy if @event_boost&.persisted? && @event_boost.session_id.blank? && !@event_boost.payment_completed?
    halt 400, { error: 'There was an error creating the boost.' }.to_json
  end

  post '/event_boosts/stripe_webhook' do
    endpoint_secret = ENV['STRIPE_ENDPOINT_SECRET_EVENT_BOOSTS']
    halt 200 unless endpoint_secret.present?

    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    begin
      stripe_event = Stripe::Webhook.construct_event(payload, sig_header, endpoint_secret)
    rescue Stripe::SignatureVerificationError => e
      ErrorTracking.notify(e)
      halt 200
    end

    if stripe_event['type'] == 'checkout.session.completed'
      session = stripe_event['data']['object']
      if (event_boost = EventBoost.find_by(session_id: session.id, payment_completed: false))
        event_boost.set(payment_completed: true)
        event_boost.send_admin_notification
      end
    end

    halt 200
  end
end
