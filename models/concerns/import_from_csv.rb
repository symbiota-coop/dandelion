module ImportFromCsv
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :import_from_csv
  end

  def import_from_csv(csv, association)
    CSV.parse(csv, headers: true, header_converters: [:downcase, :symbol]).each do |row|
      email = row[:email]
      account_hash = { name: row[:name], email: row[:email], password: Account.generate_password }
      account = Account.find_by(email: email.downcase)
      account ||= Account.new(account_hash)
      begin
        if account.persisted?
          account.update_attributes!(account_hash.map { |k, v| [k, v] if v }.compact.to_h)
        else
          account.save!
        end
        send(association).create account: account
      rescue StandardError
        next
      end
    end
  end
end
