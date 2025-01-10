class StripeRowSplitter
  def self.split(csv_string)
    csv = CSV.parse(csv_string, headers: true)

    # Process each row
    processed_rows = csv.flat_map do |row|
      description = row['Description']
      base_desc, ticket_info = description.rpartition(':').values_at(0, 2).map(&:strip)

      # Parse ticket information
      ticket_parts = ticket_info.split(',').map(&:strip)

      # Initialize variables
      ticket_amount = 0
      donation_amount = 0

      # Process each part (ticket, donation)
      ticket_types = []
      ticket_parts.each do |part|
        if part.match?(/£\d+\s+donation/)
          donation_amount = part.match(/£(\d+)\s+donation/)[1].to_f
        elsif part.match?(/.*£\d+x\d+/)
          ticket_types << part
          price, quantity = part.match(/£(\d+)x(\d+)/)[1, 2].map(&:to_f)
          ticket_amount += price * quantity
        end
      end

      results = []

      # Create separate row for each ticket type
      ticket_types.each do |ticket_type|
        price, quantity = ticket_type.match(/£(\d+)x(\d+)/)[1, 2].map(&:to_f)
        ticket_row = row.to_h
        ticket_row['Description'] = "#{base_desc}: #{ticket_type}"
        ticket_row['Amount'] = (price * quantity).round(2).to_s
        results << ticket_row
      end

      # Only create donation row if there's a donation
      if donation_amount > 0
        donation_row = row.to_h
        # Format donation amount without trailing zeros if it's a whole number
        formatted_donation = donation_amount.to_i == donation_amount ? donation_amount.to_i : donation_amount
        donation_row['Description'] = "#{base_desc}: £#{formatted_donation} donation"
        donation_row['Amount'] = donation_amount.to_s
        results << donation_row
      end

      results
    end

    CSV.generate do |output_csv|
      output_csv << csv.headers
      processed_rows.each do |row|
        output_csv << row.values
      end
    end
  end
end
