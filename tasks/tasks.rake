namespace :organisations do
  task set_counts: :environment do
    Organisation.all.each do |organisation|
      monthly_donations_count = organisation.organisationships.and(:monthly_donation_method.ne => nil).and(:monthly_donation_method.ne => 'Other').map do |organisationship|
        Money.new(
          organisationship.monthly_donation_amount * 100,
          organisationship.monthly_donation_currency
        )
      end.sum
      monthly_donations_count = monthly_donations_count.format(no_cents: true) if monthly_donations_count > 0

      organisation.update_paid_up
      organisation.set(subscribed_accounts_count: organisation.subscribed_accounts.count)
      organisation.set(monthly_donors_count: organisation.monthly_donors.count)
      organisation.set(monthly_donations_count: monthly_donations_count)
    end
  end

  task sync_monthly_donations: :environment do
    Organisation.and(:gocardless_access_token.ne => nil).each do |organisation|
      organisation.sync_with_gocardless
    end
    Organisation.and(:patreon_api_key.ne => nil).each do |organisation|
      organisation.sync_with_patreon
    end
  end
end

namespace :services do
  task delete_stale_uncompleted_bookings: :environment do
    Booking.incomplete.and(:created_at.lt => 1.hour.ago).destroy_all
  end
end

namespace :gatherings do
  task clear_up_optionships: :environment do
    Gathering.and(clear_up_optionships: true).each do |gathering|
      gathering.clear_up_optionships!
    end
  end

  task check_seeds_accounts: :environment do
    Gathering.and(:seeds_username.ne => nil).each do |gathering|
      gathering.check_seeds_account
    end
  end

  task check_evm_accounts: :environment do
    Gathering.and(:evm_address.ne => nil).each do |gathering|
      gathering.check_evm_account
    end
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
      account.recommended_people
      account.recommended_events(events_with_participant_ids)
    end
  end

  task check_seeds_accounts: :environment do
    Organisation.and(:seeds_username.ne => nil).each do |organisation|
      organisation.check_seeds_account if Order.and(:payment_completed.ne => true, :seeds_secret.ne => nil, :event_id.in => organisation.events.pluck(:id)).count > 0
    end
  end

  task check_evm_accounts: :environment do
    Organisation.and(:evm_address.ne => nil).each do |organisation|
      organisation.check_evm_account if Order.and(:payment_completed.ne => true, :evm_secret.ne => nil, :event_id.in => organisation.events.pluck(:id)).count > 0
    end
  end

  task delete_stale_uncompleted_orders: :environment do
    Order.incomplete.and(:created_at.lt => 1.hour.ago).destroy_all
  end

  task send_feedback_requests: :environment do
    Event.and(:end_time.gte => Date.yesterday, :end_time.lt => Date.today).each do |event|
      event.send_feedback_requests
    end
  end

  task send_reminders: :environment do
    Event.and(:start_time.gte => Date.tomorrow, :start_time.lt => Date.tomorrow + 1).each do |event|
      event.send_reminders
    end
  end

  task send_star_reminders: :environment do
    Event.and(:start_time.gte => Date.tomorrow + 6, :start_time.lt => Date.tomorrow + 7).each do |event|
      event.send_star_reminders
    end

    task send_payment_reminders: :environment do
      TicketType.and(name: /payment plan/i).each do |ticket_type|
        ticket_type.send_payment_reminder
      end
    end
  end

  task transfer_events: :environment do
    session = GoogleDrive::Session.from_config(OpenStruct.new(
                                                 client_id: ENV['GOOGLE_DRIVE_CLIENT_ID'],
                                                 client_secret: ENV['GOOGLE_DRIVE_CLIENT_SECRET'],
                                                 refresh_token: ENV['GOOGLE_DRIVE_REFRESH_TOKEN'],
                                                 scope: ENV['GOOGLE_DRIVE_SCOPE'].split(',')
                                               ))

    worksheet_name = 'Dandelion events'
    worksheet = session.spreadsheet_by_key(ENV['DANDELION_EVENTS_DASHBOARD_KEY']).worksheets.find { |worksheet| worksheet.title == worksheet_name }
    rows = []

    event_ids = worksheet.instance_variable_get(:@session).sheets_service.get_spreadsheet_values(
      worksheet.spreadsheet.id,
      'Dandelion events!A2:A'
    ).values.flatten

    Organisation.find('5ddfa9559009af00069c5132').events.live.and(:id.nin => event_ids, :start_time.gte => '2020-06-01').each do |event|
      row = { id: event.id.to_s }
      rows << row
    end

    worksheet.instance_variable_get(:@session).sheets_service.append_spreadsheet_value(
      worksheet.spreadsheet.id,
      worksheet_name,
      Google::Apis::SheetsV4::ValueRange.new(values: rows.reverse.map(&:values)),
      value_input_option: 'USER_ENTERED'
    )

    # worksheet.insert_rows(worksheet.num_rows + 1, rows.reverse.map(&:values))
    # worksheet.save
  end
end

namespace :stripe do
  task transfer_charges: :environment do
    from = Date.today - 2
    to = Date.today - 1
    Stripe.api_key = ENV['STRIPE_PS_SK']
    Stripe.api_version = '2020-08-27'
    charges = Stripe::Charge.list(created: { gte: Time.utc(from.year, from.month, from.day).to_i, lt: Time.utc(to.year, to.month, to.day).to_i })

    session = GoogleDrive::Session.from_config(OpenStruct.new(
                                                 client_id: ENV['GOOGLE_DRIVE_CLIENT_ID'],
                                                 client_secret: ENV['GOOGLE_DRIVE_CLIENT_SECRET'],
                                                 refresh_token: ENV['GOOGLE_DRIVE_REFRESH_TOKEN'],
                                                 scope: ENV['GOOGLE_DRIVE_SCOPE'].split(',')
                                               ))

    worksheet_name = 'Stripe charges'
    worksheet = session.spreadsheet_by_key(ENV['DANDELION_EVENTS_DASHBOARD_KEY']).worksheets.find { |worksheet| worksheet.title == worksheet_name }
    rows = []
    charges.auto_paging_each do |charge|
      row = {}
      %w[id amount application_fee application_fee_amount balance_transaction created currency customer description destination payment_intent].each do |f|
        row[f] = case f
                 when 'created'
                   Time.at(charge[f]).utc.strftime('%Y-%m-%d %H:%M:%S +0000')
                 else
                   charge[f]
                 end
      end
      %w[de_event_id de_order_id de_account_id de_donation_revenue de_ticket_revenue de_discounted_ticket_revenue de_percentage_discount de_percentage_discount_monthly_donor de_credit_applied].each do |f|
        row[f] = charge['metadata'][f]
      end
      puts row['created']
      rows << row
    end

    worksheet.instance_variable_get(:@session).sheets_service.append_spreadsheet_value(
      worksheet.spreadsheet.id,
      worksheet_name,
      Google::Apis::SheetsV4::ValueRange.new(values: rows.reverse.map(&:values)),
      value_input_option: 'USER_ENTERED'
    )

    # worksheet.insert_rows(worksheet.num_rows + 1, rows.reverse.map(&:values))
    # worksheet.save
  end

  task transfer_transactions: :environment do
    from = Date.today - 2
    to = Date.today - 1
    Stripe.api_key = ENV['STRIPE_PS_SK']
    Stripe.api_version = '2020-08-27'

    run = Stripe::Reporting::ReportRun.create({
                                                report_type: 'balance_change_from_activity.itemized.1',
                                                parameters: {
                                                  interval_start: Time.utc(from.year, from.month, from.day).to_i,
                                                  interval_end: Time.utc(to.year, to.month, to.day).to_i
                                                }
                                              })

    until run.result
      sleep 5
      run = Stripe::Reporting::ReportRun.retrieve(run.id)
    end

    uri = URI(run.result.url)
    csv = nil
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new uri.request_uri
      request.basic_auth ENV['STRIPE_PS_SK'], ''
      response = http.request request
      csv = CSV.parse(response.body.encode('utf-8', invalid: :replace, undef: :replace, replace: '_'), headers: true, header_converters: :symbol)
    end

    session = GoogleDrive::Session.from_config(OpenStruct.new(
                                                 client_id: ENV['GOOGLE_DRIVE_CLIENT_ID'],
                                                 client_secret: ENV['GOOGLE_DRIVE_CLIENT_SECRET'],
                                                 refresh_token: ENV['GOOGLE_DRIVE_REFRESH_TOKEN'],
                                                 scope: ENV['GOOGLE_DRIVE_SCOPE'].split(',')
                                               ))

    worksheet_name = 'Stripe transactions'
    worksheet = session.spreadsheet_by_key(ENV['DANDELION_EVENTS_DASHBOARD_KEY']).worksheets.find { |worksheet| worksheet.title == worksheet_name }
    rows = []
    csv.each do |row|
      row = row.to_hash
      %w[created_utc available_on_utc].each do |f|
        row[f.to_sym] = "#{row[f.to_sym]} +0000"
      end
      %w[gross fee net].each do |f|
        row["#{f}_gbp".to_sym] = Money.new(row[f.to_sym].to_f * 100, row[:currency]).exchange_to('GBP').cents.to_f / 100.to_f
      end
      rows << row
    end

    worksheet.instance_variable_get(:@session).sheets_service.append_spreadsheet_value(
      worksheet.spreadsheet.id,
      worksheet_name,
      Google::Apis::SheetsV4::ValueRange.new(values: rows.map(&:values)),
      value_input_option: 'USER_ENTERED'
    )

    # worksheet.insert_rows(worksheet.num_rows + 1, rows.map(&:values))
    # worksheet.save
  end
end
