namespace :hourly do
  task errands: :environment do
    puts 'delete stale uncompleted orders'
    Order.incomplete.and(:created_at.lt => 1.hour.ago).destroy_all
    puts 'update monthly contributions current month'
    MonthlyContributionsCalculator.update_current_month
    puts 'check for payments'
    Organisation.and(:evm_address.ne => nil).each do |organisation|
      organisation.check_evm_account if Order.and(:payment_completed.ne => true, :evm_secret.ne => nil, :event_id.in => organisation.events.pluck(:id)).exists?
    end
    Event.live.and(:oc_slug.ne => nil).each do |event|
      event.check_oc_event if event.orders.and(:payment_completed.ne => true, :oc_secret.ne => nil, :event_id => event.id).exists?
    end
    Gathering.and(:evm_address.ne => nil).each(&:check_evm_account)
  end
end

namespace :morning do
  task errands: :environment do
    puts 'feedback requests'
    Event.live.and(:end_time.gte => Date.yesterday, :end_time.lt => Date.today).each { |event| event.send_feedback_requests(:all) }
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
    puts 'delete old page views and sign ins'
    PageView.and(:created_at.lt => 30.days.ago).delete_all
    SignIn.and(:created_at.lt => 1.year.ago).delete_all
    puts 'create organisation edges'
    OrganisationEdge.delete_all
    OrganisationEdge.create_all(Organisation.and(:followers_count.gte => 50).and(:id.nin => Organisation.order('followers_count desc').limit(1).pluck(:id)))
    puts 'clear up optionships'
    Gathering.and(clear_up_optionships: true).each(&:clear_up_optionships!)
    puts 'update event tags for select'
    EventTag.update_tags_for_select
    puts 'update feedback counts'
    EventFeedback.update_event_feedbacks_as_facilitator_counts
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

namespace :other do
  task check_squarespace_signup: :environment do
    CheckSquarespaceSignup.check
  end
end

namespace :db do
  task ensure_text_indexes: :environment do
    puts 'Ensuring text search indexes exist...'
    
    # Get all models that include Searchable
    searchable_models = [Event, Gathering, EventTag, Pmail, LocalGroup, Activity, Organisation, Account]
    
    searchable_models.each do |model|
      begin
        puts "Creating text index for #{model.name}..."
        model.ensure_text_index
        puts "✓ Text index created/verified for #{model.name}"
      rescue => e
        puts "✗ Failed to create text index for #{model.name}: #{e.message}"
      end
    end
    
    puts 'Text search indexes setup complete!'
  end
end
