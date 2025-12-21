module SendFollowersCsv
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_followers_csv
  end

  def send_followers_csv(account, association)
    csv = CSV.generate do |csv|
      csv << %w[name firstname lastname email unsubscribed]
      send(association).each do |m|
        csv << [
          m.account.name,
          m.account.firstname,
          m.account.lastname,
          Organisation.admin?(organisation, account) ? m.account.email : '',
          (1 if m.unsubscribed)
        ]
      end
    end

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html EmailHelper.html(:csv)

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'followers.csv')

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
    file.close
    file.unlink
  end
end
