module ImportFromCsv
  extend ActiveSupport::Concern

  UTF8_BOM = "\xEF\xBB\xBF".b
  # Excel's "Unicode Text" is UTF-16 with a BOM, and tab-separated
  UTF16_BOMS = { "\xFF\xFE".b => Encoding::UTF_16LE, "\xFE\xFF".b => Encoding::UTF_16BE }.freeze

  included do
    handle_asynchronously :import_from_csv
  end

  def self.read(upload)
    raise ArgumentError, 'expected an uploaded file' unless upload.is_a?(Tempfile)

    sanitize(File.binread(upload.path))
  end

  def self.sanitize(csv)
    csv = csv.to_s.b
    UTF16_BOMS.each do |bom, encoding|
      next unless csv.start_with?(bom)

      return csv.byteslice(bom.bytesize..).force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
    end
    csv = csv.delete_prefix(UTF8_BOM)
    utf8 = csv.dup.force_encoding(Encoding::UTF_8)
    return utf8 if utf8.valid_encoding?

    csv.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
  end

  def self.parse(csv)
    header = csv[/\A[^\r\n]*/]
    col_sep = header.include?("\t") && !header.include?(',') ? "\t" : ','
    CSV.parse(csv, headers: true, header_converters: %i[downcase symbol], col_sep: col_sep)
  end

  # Why the CSV can't be imported, or nil if it can
  def self.error(csv)
    'The CSV needs a column headed email' unless parse(csv).headers.include?(:email)
  rescue CSV::MalformedCSVError => e
    "The CSV couldn't be read (there's a problem on line #{e.line_number})"
  end

  def import_from_csv(csv, association)
    ImportFromCsv.parse(ImportFromCsv.sanitize(csv)).each do |row|
      email = row[:email].to_s.strip.downcase
      next if email.empty?

      account = Account.find_by(email: email)
      account ||= Account.new(name: row[:name], email: email, password: Account.generate_password)
      begin
        account.save! unless account.persisted?
        send(association).create account: account
      rescue StandardError
        next
      end
    end
  end
end
