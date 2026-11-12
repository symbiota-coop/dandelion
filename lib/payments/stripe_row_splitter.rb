# Splits each row of a Stripe payments CSV into a row per ticket type and one per donation, read from the payment's
# description (Order#description), so that a payment's rows add up to what was charged. Amounts taken off the whole
# order (a fixed discount, credit applied) are spread across the ticket rows in proportion to each row's amount. A row
# whose description can't be read, or doesn't add up to the row's Amount, is kept as it is, so no payment is lost.
class StripeRowSplitter
  # Order#description joins its parts with ', '; a comma inside an amount (£1,000, €2,50) is never followed by a space
  PART_SEPARATOR = ', '.freeze

  def self.split(csv_string)
    csv = CSV.parse(csv_string, headers: true)

    processed_rows = csv.flat_map do |row|
      next [] if row.fields.all?(&:blank?)

      new(row).rows || [row.to_h]
    end

    CSV.generate do |output_csv|
      output_csv << csv.headers
      processed_rows.each do |row|
        output_csv << row.values
      end
    end
  end

  def initialize(row)
    @row = row
  end

  # The split rows, or nil if the row should be kept as it is
  def rows
    description = @row['Description']
    return if description.blank?
    return unless (patterns = part_patterns)

    # The event's name or location may contain ': ', so try each until what follows reads as an order's parts
    separators = description.enum_for(:scan, ': ').map { Regexp.last_match.begin(0) }
    separators.each do |index|
      order = parse_parts(description[(index + 2)..].split(PART_SEPARATOR).map(&:strip), patterns)
      next unless order

      split = split_rows(description[0...index], order)
      return split if split
    end
    nil
  end

  private

  def currency
    @currency ||= Money::Currency.new(@row['Currency'].blank? ? 'GBP' : @row['Currency'])
  end

  # The parts Order#description_elements writes, with amounts as Money#format writes them in the row's currency
  # (£1,234.50, €1.234,50, SEK 1,234.50, CHF 1'234.50, 1 234,50 zł)
  def part_patterns
    prefix, suffix = Money.new(100, currency).format(no_cents_if_whole: true).split('1', 2)
    separator = Regexp.escape(currency.thousands_separator)
    decimal_mark = Regexp.escape(currency.decimal_mark)
    money = "#{Regexp.escape(prefix)}(?<amount>\\d{1,3}(?:#{separator}\\d{3})*(?:#{decimal_mark}\\d{2})?)#{Regexp.escape(suffix)}"
    {
      ticket: /\A(?:.*?\S\s+)?#{money}x(?<quantity>\d+)\z/,
      percentage: /\A(?<percentage>\d+)% discount\z/,
      donation: /\A#{money} donation\z/,
      dandelion_donation: /\A#{money} donation to Dandelion\z/,
      credit: /\A#{money} credit applied\z/,
      fixed_discount: /\A#{money} discount\z/
    }
  rescue Money::Currency::UnknownCurrency
    nil
  end

  def cents(amount)
    (BigDecimal(amount.delete(currency.thousands_separator).tr(currency.decimal_mark, '.')) * 100).to_i
  end

  # Reads every part, or returns nil if any part isn't one Order#description_elements writes
  def parse_parts(parts, patterns)
    matches = parts.map do |part|
      patterns.lazy.map { |kind, pattern| [kind, part.match(pattern)] }.find { |_kind, match| match }
    end
    return if matches.any?(nil)

    order = { tickets: [], percentages: [], donations: [], dandelion_donations: 0, deductions: 0, deduction_parts: [] }
    parts.zip(matches).each do |part, (kind, match)|
      case kind
      when :ticket
        order[:tickets] << { text: part, price: cents(match[:amount]), quantity: match[:quantity].to_i }
      when :percentage
        order[:percentages] << match[:percentage].to_i
        order[:deduction_parts] << part
      when :donation
        order[:donations] << { text: part, amount: cents(match[:amount]) }
      when :dandelion_donation
        order[:dandelion_donations] += cents(match[:amount])
      when :credit, :fixed_discount
        order[:deductions] += cents(match[:amount])
        order[:deduction_parts] << part
      end
    end
    # An order has at most a discount code's percentage and a monthly donor's
    order unless order[:percentages].length > 2 || (order[:tickets].empty? && order[:donations].empty?)
  end

  def split_rows(base_description, order)
    ticket_amounts = order[:tickets].map do |ticket|
      # Each ticket's price is discounted and rounded to the penny as on the order, then multiplied by the quantity
      discounted = Ticket.discounted_price(ticket[:price] / 100.0, order[:percentages][0], order[:percentages][1])
      (BigDecimal(discounted.to_s) * 100).to_i * ticket[:quantity]
    end
    donation_amounts = order[:donations].map { |donation| donation[:amount] }

    # Credit and a fixed discount come off the tickets, and only what's left of them off the donations, which an order
    # can take them from too (Bookings::Quote#running_total)
    ticket_deduction = [order[:deductions], ticket_amounts.sum].min
    ticket_amounts = deduct(ticket_amounts, ticket_deduction)
    donation_deduction = order[:deductions] - ticket_deduction
    return if donation_deduction > donation_amounts.sum

    donation_amounts = deduct(donation_amounts, donation_deduction)
    return unless adds_up?(ticket_amounts.sum + donation_amounts.sum + order[:dandelion_donations])

    ticket_rows = order[:tickets].zip(ticket_amounts).map do |ticket, amount|
      split_row("#{base_description}: #{([ticket[:text]] + order[:deduction_parts]).join(PART_SEPARATOR)}", amount)
    end
    donation_rows = order[:donations].zip(donation_amounts).map do |donation, amount|
      parts = [donation[:text]]
      parts += order[:deduction_parts] if donation_deduction.positive?
      split_row("#{base_description}: #{parts.join(PART_SEPARATOR)}", amount)
    end
    ticket_rows + donation_rows
  end

  # Takes an amount off a set of amounts in proportion to each, rounded to the penny, with the rounding remainder on
  # the largest amount so the total taken off is exact
  def deduct(amounts, deduction)
    total = amounts.sum
    return amounts if deduction.zero? || total.zero?

    largest = amounts.index(amounts.max)
    shares = amounts.map { |amount| Rational(deduction * amount, total).round }
    shares[largest] = deduction - (shares.sum - shares[largest])
    amounts.zip(shares).map { |amount, share| amount - share }
  end

  # Amounts are written as Stripe's export writes them, e.g. 1234.50
  def split_row(description, amount)
    @row.to_h.merge('Description' => description, 'Amount' => format('%.2f', BigDecimal(amount) / 100))
  end

  # The rows and any donation to Dandelion (left out, as it isn't the organisation's income) should come to the row's
  # Amount, or the description isn't the whole story of what was charged
  def adds_up?(total)
    return true if @row['Amount'].blank?

    charged = BigDecimal(@row['Amount'].delete(','), exception: false)
    charged && (charged * 100) == total
  end
end
