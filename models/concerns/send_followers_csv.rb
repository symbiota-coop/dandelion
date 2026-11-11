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

    Mailer.deliver(:csv, to: account, subject: 'Dandelion CSV export', attachments: { 'followers.csv' => csv })
  end
end
