namespace :hourly do
  task errands: :environment do
    Errand.step('hourly errands') do
      now = Time.now
      Errand.step('feedback requests') do
        feedback_window_start = now - (Event::MAX_FEEDBACK_HOURS_AFTER + 1).hours
        feedback_events = Event.live.and(:sent_feedback_requests_at => nil, :end_time.ne => nil, :end_time.lte => now + 1.hour, :end_time.gte => feedback_window_start).to_a
        puts "feedback requests: checking #{feedback_events.length} event(s) within the supported scheduling window"
        feedback_events.each do |event|
          next unless event.feedback_due_within?(1.hour, now)

          puts "feedback requests: enqueueing event=#{event.id} slug=#{event.slug} name=#{event.name.inspect} end_time=#{event.end_time} feedback_hours_after=#{event.feedback_hours_after.inspect}"
          event.send_feedback_requests(:all)
        end
      end
      Errand.step('clean up old temp files') do
        system('find /tmp -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null')
      end
      Errand.step('delete stale uncompleted orders') do
        Order.incomplete.and(:created_at.lt => Order::UNPAID_HOLD.ago).destroy_all
      end
      Errand.step('update paid up status for organisations with orders in the last hour') do
        Organisation.and(:id.in => Event.and(:id.in => Order.complete.and(:created_at.gt => 1.hour.ago).pluck(:event_id)).pluck(:organisation_id)).each(&:update_paid_up_without_delay)
      end
      Errand.step('update monthly contributions current month') do
        MonthlyContributionsCalculator.update_current_month
      end
      Errand.step('check for payments') do
        Organisation.and(:evm_address.ne => nil).each do |organisation|
          organisation.check_evm_account if Order.and(:payment_completed => false, :evm_secret.ne => nil, :event_id.in => organisation.events.pluck(:id)).exists?
        end
        Event.live.and(:oc_slug.ne => nil).each do |event|
          event.check_oc_event if event.orders.and(:payment_completed => false, :oc_secret.ne => nil, :event_id => event.id).exists?
        end
        Gathering.and(:evm_address.ne => nil).each(&:check_evm_account)
      end
      Errand.step('event reminders') do
        Event.live.and(:start_time.gt => now, :reminder_hours_before.ne => nil, :sent_reminders_at => nil).each do |event|
          next unless event.reminder_due_within?(1.hour, now)

          event.send_reminders(:all)
        end
      end
      Errand.step('sync iCal imports') do
        Organisation.all.each do |organisation|
          next if organisation.calendar_import_urls_a.empty?

          organisation.sync_calendar_imports
        end
      end
      Errand.step('autoblock ASNs') do
        Asn.autoblock
      end
    end
  end
end

namespace :late do
  task errands: :environment do
    Errand.step('late errands') do
      Errand.step('public home ticket stats (daily)') do
        Ticket.refresh_home_page_stats!
      end
      Errand.step('generate Dandelion Daily') do
        Daily.publish(Date.today)
        Daily.locations.each { |location| Daily.publish(Date.today, location: location) }
      end
      Errand.step('create organisation edges') do
        OrganisationEdge.delete_all
        OrganisationEdge.create_all(Organisation.and(:followers_count.gte => 50))
      end
      Errand.step('clear up optionships') do
        Gathering.and(clear_up_optionships: true).each(&:clear_up_optionships!)
      end
      Errand.step('update event tags for select') do
        EventTag.update_tags_for_select
      end
      Errand.step('update feedback counts') do
        EventFeedback.update_event_feedbacks_as_facilitator_details
      end
      Errand.step('monthly contributions') do
        MonthlyContributionsCalculator.calculate
      end
      Errand.step('MaxMinder upload') do
        MaxMinder.upload
      end
      # Before set_counts, so the monthly donation totals include tonight's donors
      Errand.step('sync monthly donations') do
        Organisation.and(:gocardless_subscriptions => true, :gocardless_access_token.ne => nil).each(&:sync_with_gocardless)
        Organisation.and(:patreon_refresh_token.ne => nil).each(&:sync_with_patreon)
      end
      Errand.step('set counts, update paid up status and stripe topup') do
        Organisation.all.each do |organisation|
          organisation.set_counts
          organisation.update_paid_up_without_delay
          organisation.stripe_topup if organisation.stripe_customer_id
        end
      end
      Errand.step('sync stripe subscriptions') do
        Account.reconcile_stripe_subscriptions
      end
      Errand.step('stripe transfers') do
        Organisation.and(:stripe_client_id.ne => nil).each do |organisation|
          StripeCharge.transfer(organisation)
          StripeTransaction.transfer(organisation)
        end
      end
      Errand.step('stripe balances and fees') do
        StripeCharge.and(:id.in => StripeTransaction.and(:created_at.gt => 1.day.ago).pluck(:stripe_charge_id)).each do |stripe_charge|
          stripe_charge.set(balance_float: stripe_charge.balance_from_transactions)
          stripe_charge.set(fees_float: stripe_charge.fees_from_transactions)
        end
      end
      Errand.step('location summaries') do
        Location.all.each(&:generate_summary)
      end
      Errand.step('event recommendations') do
        Event.recommend
      end
      Errand.step('mailgun delivery stats alert') do
        MailgunDeliveryStats.check_and_notify
      end
      Errand.step('star reminders') do
        Event.live.and(:start_time.gte => Date.tomorrow + 6, :start_time.lt => Date.tomorrow + 7).each { |event| event.send_star_reminders(:all) }
      end
      if ENV['ATPROTO_HANDLE'].present? && ENV['ATPROTO_APP_PASSWORD'].present?
        Errand.step('sync AT Protocol events') do
          Event.sync_atproto(hours: 24)
        end
        Errand.step('verify AT Protocol collection') do
          Event.verify_atproto_collection(fix: true)
        end
      end
    end
  end
end
