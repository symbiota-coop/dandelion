namespace :hourly do
  task errands: :environment do
    puts 'feedback requests'
    Event.live.and(:end_time.gt => Time.now.beginning_of_hour, :end_time.lte => Time.now.beginning_of_hour + 1.hour).each { |event| event.send_feedback_requests(:all) }
    puts 'clean up old temp files'
    system('find /tmp -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null')
    puts 'delete stale uncompleted orders'
    Order.incomplete.and(:created_at.lt => 1.hour.ago).destroy_all
    puts 'update paid up status for organisations with orders in the last hour'
    Organisation.and(:id.in => Event.and(:id.in => Order.complete.and(:created_at.gt => 1.hour.ago).pluck(:event_id)).pluck(:organisation_id)).each(&:update_paid_up_without_delay)
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
    puts 'event reminders'
    now = Time.now
    Event.live.and(:start_time.gt => now, :reminder_hours_before.ne => nil, :sent_reminders_at => nil).each do |event|
      next unless event.reminder_due_within?(1.hour, now)

      event.send_reminders(:all)
    end
    puts 'sync iCal imports'
    Organisation.all.each do |organisation|
      next if organisation.calendar_import_urls_a.empty?

      organisation.sync_calendar_imports
    end
    current_hour = TZInfo::Timezone.get(Asn::TIMEZONE).to_local(Time.now.utc).hour
    if (current_hour % Asn::WINDOW_LENGTH).zero?
      puts 'autoblock ASNs'
      Asn.autoblock
    end
  end
end

namespace :morning do
  task errands: :environment do
    puts 'star reminders'
    Event.live.and(:start_time.gte => Date.tomorrow + 6, :start_time.lt => Date.tomorrow + 7).each { |event| event.send_star_reminders(:all) }
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
    puts 'set counts, update paid up status and stripe topup'
    Organisation.all.each do |organisation|
      organisation.set_counts
      organisation.update_paid_up_without_delay
      organisation.stripe_topup if organisation.stripe_customer_id
    end
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
    puts 'mailgun delivery stats alert'
    MailgunDeliveryStats.check_and_notify
    puts 'done!'
  end
end
