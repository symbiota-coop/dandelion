module ImportFromCsv
  extend ActiveSupport::Concern

  UTF8_BOM = "\xEF\xBB\xBF".b

  included do
    handle_asynchronously :import_from_csv
  end

  def self.read(upload)
    path = upload.respond_to?(:path) ? upload.path : upload
    sanitize(File.binread(path))
  end

  def self.sanitize(csv)
    csv = csv.to_s.b.delete_prefix(UTF8_BOM)
    utf8 = csv.dup.force_encoding(Encoding::UTF_8)
    return utf8 if utf8.valid_encoding?

    csv.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
  end

  def import_from_csv(csv, association)
    csv = ImportFromCsv.sanitize(csv)
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
