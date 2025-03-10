namespace :hourly do
  task errands: :environment do
    logger.info 'check for payments'
    Organisation.and(:evm_address.ne => nil).each do |organisation|
      organisation.check_evm_account if Order.and(:payment_completed.ne => true, :evm_secret.ne => nil, :event_id.in => organisation.events.pluck(:id)).count > 0
    end
    Event.live.and(:oc_slug.ne => nil).each do |event|
      event.check_oc_event if event.orders.and(:payment_completed.ne => true, :oc_secret.ne => nil, :event_id => event.id).count > 0
    end
    Gathering.and(:evm_address.ne => nil).each(&:check_evm_account)
    logger.info 'delete stale uncompleted orders'
    Order.incomplete.and(:created_at.lt => 1.hour.ago).destroy_all
  end
end

namespace :morning do
  task errands: :environment do
    logger.info 'feedback requests'
    Event.live.and(:end_time.gte => Date.yesterday, :end_time.lt => Date.today).each { |event| event.send_feedback_requests(:all) }
    logger.info 'event reminders'
    Event.live.and(:start_time.gte => Date.tomorrow, :start_time.lt => Date.tomorrow + 1).each { |event| event.send_reminders(:all) }
    logger.info 'star reminders'
    Event.live.and(:start_time.gte => Date.tomorrow + 6, :start_time.lt => Date.tomorrow + 7).each { |event| event.send_star_reminders(:all) }
    logger.info 'payment reminders'
    TicketType.and(name: /payment plan/i).each(&:send_payment_reminder) if Date.today.day == 1
  end
end

namespace :late do
  task errands: :environment do
    logger.info 'get Dandelion Daily'
    Faraday.get("#{ENV['BASE_URI']}/daily?date=#{Date.today.to_fs(:db_local)}", {}, { 'X-Requested-With' => 'XMLHttpRequest' })
    logger.info 'delete old page views and sign ins'
    PageView.and(:created_at.lt => 30.days.ago).delete_all
    SignIn.and(:created_at.lt => 1.year.ago).delete_all
    logger.info 'create organisation edges'
    OrganisationEdge.delete_all
    OrganisationEdge.create_all(Organisation.and(:followers_count.gte => 50).and(:id.nin => Organisation.order('followers_count desc').limit(1).pluck(:id)))
    logger.info 'clear up optionships'
    Gathering.and(clear_up_optionships: true).each(&:clear_up_optionships!)
    logger.info 'update feedback counts'
    EventFeedback.update_facilitator_feedback_counts
    logger.info 'monthly contributions'
    MonthlyContributionsCalculator.calculate
    logger.info 'MaxMinder upload'
    MaxMinder.upload
    logger.info 'set counts'
    Organisation.set_counts
    logger.info 'sync monthly donations'
    Organisation.and(:gocardless_access_token.ne => nil).each(&:sync_with_gocardless)
    Organisation.and(:patreon_api_key.ne => nil).each(&:sync_with_patreon)
    logger.info 'stripe transfers'
    Organisation.and(:stripe_client_id.ne => nil).each do |organisation|
      StripeCharge.transfer(organisation)
      StripeTransaction.transfer(organisation)
    end
    StripeCharge.and(:id.in => StripeTransaction.and(:created_at.gt => 1.day.ago).pluck(:stripe_charge_id)).each do |stripe_charge|
      stripe_charge.set(balance_float: stripe_charge.balance_from_transactions)
      stripe_charge.set(fees_float: stripe_charge.fees_from_transactions)
    end
    logger.info 'event recommendations'
    Event.recommend
  end

  namespace :other do
    task check_squarespace_signup: :environment do
      CheckSquarespaceSignup.check
    end

    task code_to_markdown: :environment do
      content = ''
      allowed_file_extensions = %w[css js erb rake rb]
      Dir.glob('**/*').each do |file|
        next if File.directory?(file)
        next if file.starts_with?('app/assets/infinite_admin')
        next if file.starts_with?('app/assets/javascripts/ext')
        next unless allowed_file_extensions.include?(File.extname(file).delete('.'))

        puts file
        content += "# #{file}\n\n"
        content += File.read(file)
        content += "\n\n"
      end
      File.write('code.md', content)
    end
  end
end
