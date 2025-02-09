namespace :dump do
  task code: :environment do
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

namespace :daily do
  task get: :environment do
    Faraday.get("#{ENV['BASE_URI']}/daily?date=#{Date.today.to_fs(:db_local)}", {}, { 'X-Requested-With' => 'XMLHttpRequest' })
  end
end

namespace :max_minder do
  task upload: :environment do
    MaxMinder.upload
  end
end

namespace :tidy_up do
  task delete_all: :environment do
    PageView.and(:created_at.lt => 30.days.ago).delete_all
    SignIn.and(:created_at.lt => 1.year.ago).delete_all
  end
end

namespace :organisations do
  task check_squarespace_signup: :environment do
    Account.find_by(email: ENV['SQUARESPACE_EMAIL']).try(:destroy)

    f = Ferrum::Browser.new
    f.go_to(ENV['SQUARESPACE_URL'])
    f.css('form input')[0].focus.type(ENV['SQUARESPACE_NAME'])
    f.css('form input')[1].focus.type(ENV['SQUARESPACE_EMAIL'])
    f.execute("document.getElementById('#{f.css('form input')[0]['id']}').scrollIntoView()")
    10.times do
      f.at_css('form button').click
      sleep 1
    end
    organisation = Organisation.find_by(slug: ENV['SQUARESPACE_ORGANISATION_SLUG'])
    sleep 10
    raise "Squarespace: Account not created for #{ENV['SQUARESPACE_EMAIL']}" unless (account = Account.find_by(email: ENV['SQUARESPACE_EMAIL'])) && account.organisationships.find_by(organisation: organisation)
  end

  task create_edges: :environment do
    OrganisationEdge.delete_all
    OrganisationEdge.create_all(Organisation.and(:followers_count.gte => 50).and(:id.nin => Organisation.order('followers_count desc').limit(1).pluck(:id)))
  end

  task set_counts: :environment do
    Organisation.all.each do |organisation|
      monthly_donations_count = organisation.organisationships.and(:monthly_donation_method.ne => nil).and(:monthly_donation_method.ne => 'Other').map do |organisationship|
        Money.new(
          organisationship.monthly_donation_amount * 100,
          organisationship.monthly_donation_currency
        )
      end.sum
      monthly_donations_count = monthly_donations_count.format(no_cents: true) if monthly_donations_count > 0
      organisation.set(monthly_donations_count: monthly_donations_count)
      organisation.set(monthly_donors_count: organisation.monthly_donors.count)

      organisation.update_paid_up_without_delay
      if organisation.stripe_customer_id
        cr = organisation.contribution_requested
        cp = organisation.contribution_paid
        organisation.stripe_topup if cp < (Organisation.paid_up_fraction * cr)
      end

      organisation.set(subscribed_accounts_count: organisation.subscribed_accounts.count)
      organisation.set(followers_count: organisation.organisationships.count)
    end
  end

  task sync_monthly_donations: :environment do
    Organisation.and(:gocardless_access_token.ne => nil).each(&:sync_with_gocardless)
    Organisation.and(:patreon_api_key.ne => nil).each(&:sync_with_patreon)
  end

  task stripe_transfers: :environment do
    Organisation.and(:stripe_client_id.ne => nil).each do |organisation|
      StripeCharge.transfer(organisation)
      StripeTransaction.transfer(organisation)
    end
    StripeCharge.and(:id.in => StripeTransaction.and(:created_at.gt => 1.day.ago).pluck(:stripe_charge_id)).each do |stripe_charge|
      stripe_charge.set(balance_float: stripe_charge.balance_from_transactions)
      stripe_charge.set(fees_float: stripe_charge.fees_from_transactions)
    end
  end
end

namespace :gatherings do
  task clear_up_optionships: :environment do
    Gathering.and(clear_up_optionships: true).each(&:clear_up_optionships!)
  end

  task check_for_payments: :environment do
    Gathering.and(:evm_address.ne => nil).each(&:check_evm_account)
  end
end

namespace :events do
  task recommend: :environment do
    events_with_participant_ids = Event.live.public.future.map do |event|
      [event.id.to_s, event.attendees.pluck(:id).map(&:to_s)]
    end
    c = Account.recommendable.count
    Account.recommendable.each_with_index do |account, i|
      puts "#{i + 1}/#{c}"
      account.recommend_people!
      account.recommend_events!(events_with_participant_ids)
    end
  end

  task check_for_payments: :environment do
    Organisation.and(:evm_address.ne => nil).each do |organisation|
      organisation.check_evm_account if Order.and(:payment_completed.ne => true, :evm_secret.ne => nil, :event_id.in => organisation.events.pluck(:id)).count > 0
    end
    Event.live.and(:oc_slug.ne => nil).each do |event|
      event.check_oc_event if event.orders.and(:payment_completed.ne => true, :oc_secret.ne => nil, :event_id => event.id).count > 0
    end
  end

  task delete_stale_uncompleted_orders: :environment do
    Order.incomplete.and(:created_at.lt => 1.hour.ago).destroy_all
  end

  task send_feedback_requests: :environment do
    Event.live.and(:end_time.gte => Date.yesterday, :end_time.lt => Date.today).each { |event| event.send_feedback_requests(:all) }
  end

  task send_reminders: :environment do
    Event.live.and(:start_time.gte => Date.tomorrow, :start_time.lt => Date.tomorrow + 1).each { |event| event.send_reminders(:all) }
  end

  task send_star_reminders: :environment do
    Event.live.and(:start_time.gte => Date.tomorrow + 6, :start_time.lt => Date.tomorrow + 7).each { |event| event.send_star_reminders(:all) }
  end

  task send_payment_reminders: :environment do
    TicketType.and(name: /payment plan/i).each(&:send_payment_reminder) if Date.today.day == 1
  end
end

namespace :stats do
  task facilitator_feedback_counts: :environment do
    fragment = Fragment.find_or_create_by(key: 'facilitator_feedback_counts')
    feedback_counts = Account.and(:id.in => EventFacilitation.pluck(:account_id)).map do |account|
      [account.id.to_s, account.unscoped_event_feedbacks_as_facilitator.count]
    end
    fragment.update_attributes expires: 1.day.from_now, value: feedback_counts.sort_by { |_, freq| -freq }.to_json
  end

  task monthly_contributions: :environment do
    d = [Date.new(24.months.ago.year, 24.months.ago.month, 1)]
    d << (d.last + 1.month) while d.last < Date.new(Date.today.year, Date.today.month, 1)

    Stripe.api_key = ENV['STRIPE_SK']
    Stripe.api_version = '2020-08-27'

    charges_list = Stripe::Charge.list({
                                         created: {
                                           gte: d.first.to_time.to_i,
                                           lt: (d.last + 1.month).to_time.to_i
                                         },
                                         limit: 100
                                       })

    charges = []
    charges_list.auto_paging_each do |charge|
      charges << charge
    end

    application_fees_list = Stripe::ApplicationFee.list({
                                                          created: {
                                                            gte: d.first.to_time.to_i,
                                                            lt: (d.last + 1.month).to_time.to_i
                                                          },
                                                          limit: 100
                                                        })

    application_fees = []
    application_fees_list.auto_paging_each do |fee|
      application_fees << fee
    end

    fragment = Fragment.find_or_create_by(key: 'monthly_contributions')
    fragment.update_attributes expires: 1.day.from_now, value: d.map { |x|
      start_of_month = x
      end_of_month = x + 1.month

      monthly_contributions = Money.new(0, 'GBP')

      # Process charges
      charges
        .select { |c| c.created >= start_of_month.to_time.to_i && c.created < end_of_month.to_time.to_i }
        .each do |c|
          next unless c.status == 'succeeded'
          next if c.refunded
          next if ENV['STRIPE_PAYMENT_INTENTS_TO_IGNORE'] && c.payment_intent.in?(ENV['STRIPE_PAYMENT_INTENTS_TO_IGNORE'].split(','))

          monthly_contributions += Money.new(c['amount'], c['currency'])
        end

      # Process application fees
      application_fees
        .select { |f| f.created >= start_of_month.to_time.to_i && f.created < end_of_month.to_time.to_i }
        .each do |f|
          next if f.refunded

          monthly_contributions += Money.new(f['amount'], f['currency'])
        end

      monthly_contributions = monthly_contributions.exchange_to('GBP')
      ["#{Date::MONTHNAMES[x.month]} #{x.year}", monthly_contributions.to_i]
    }.to_json
  end
end
