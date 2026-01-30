namespace :hourly do
  task errands: :environment do
    puts 'feedback requests'
    Event.live.and(:end_time.gte => Time.now.beginning_of_hour, :end_time.lt => Time.now.beginning_of_hour + 1.hour).each { |event| event.send_feedback_requests(:all) }
    puts 'clean up old temp files'
    system('find /tmp -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null')
    puts 'delete stale uncompleted orders'
    Order.incomplete.and(:created_at.lt => 1.hour.ago).destroy_all
    puts 'update monthly contributions current month'
    MonthlyContributionsCalculator.update_current_month
    puts 'check for payments'
    Organisation.and(:evm_address.ne => nil).each do |organisation|
      organisation.check_evm_account if Order.and(:payment_completed => false, :evm_secret.ne => nil, :event_id.in => organisation.events.pluck(:id)).exists?
    end
    Event.live.and(:oc_slug.ne => nil).each do |event|
      event.check_oc_event if event.orders.and(:payment_completed => false, :oc_secret.ne => nil, :event_id => event.id).exists?
    end
    Gathering.and(:evm_address.ne => nil).each(&:check_evm_account)
  end
end

namespace :morning do
  task errands: :environment do
    puts 'event reminders'
    Event.live.and(:start_time.gte => Date.tomorrow, :start_time.lt => Date.tomorrow + 1).each { |event| event.send_reminders(:all) }
    puts 'star reminders'
    Event.live.and(:start_time.gte => Date.tomorrow + 6, :start_time.lt => Date.tomorrow + 7).each { |event| event.send_star_reminders(:all) }
    puts 'payment reminders'
    TicketType.and(name: /payment plan/i).each(&:send_payment_reminder) if Date.today.day == 1
  end
end

namespace :late do
  task errands: :environment do
    puts 'get Dandelion Daily'
    Faraday.get("#{ENV['BASE_URI']}/daily?date=#{Date.today.to_fs(:db_local)}", {}, { 'X-Requested-With' => 'XMLHttpRequest' })
    puts 'create organisation edges'
    OrganisationEdge.delete_all
    OrganisationEdge.create_all(Organisation.and(:followers_count.gte => 50))
    puts 'clear up optionships'
    Gathering.and(clear_up_optionships: true).each(&:clear_up_optionships!)
    puts 'update event tags for select'
    EventTag.update_tags_for_select
    puts 'update feedback counts'
    EventFeedback.update_event_feedbacks_as_facilitator_details
    puts 'monthly contributions'
    MonthlyContributionsCalculator.calculate
    puts 'MaxMinder upload'
    MaxMinder.upload
    puts 'set counts'
    Organisation.set_counts
    puts 'sync monthly donations'
    Organisation.and(:gocardless_subscriptions => true, :gocardless_access_token.ne => nil).each(&:sync_with_gocardless)
    Organisation.and(:patreon_api_key.ne => nil).each(&:sync_with_patreon)
    puts 'stripe transfers'
    Organisation.and(:stripe_client_id.ne => nil).each do |organisation|
      StripeCharge.transfer(organisation)
      StripeTransaction.transfer(organisation)
    end
    puts 'stripe balances and fees'
    StripeCharge.and(:id.in => StripeTransaction.and(:created_at.gt => 1.day.ago).pluck(:stripe_charge_id)).each do |stripe_charge|
      stripe_charge.set(balance_float: stripe_charge.balance_from_transactions)
      stripe_charge.set(fees_float: stripe_charge.fees_from_transactions)
    end
    puts 'event recommendations'
    Event.recommend
    puts 'done!'
  end
end
