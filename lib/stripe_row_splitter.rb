class StripeRowSplitter
  def self.split(csv_string)
    csv = CSV.parse(csv_string, headers: true)

    # Process each row
    processed_rows = csv.flat_map do |row|
      description = row['Description']
      next if description.blank?

      base_desc, ticket_info = description.rpartition(':').values_at(0, 2).map(&:strip)

      # Parse ticket information
      ticket_parts = []
      current_part = ''
      ticket_info.each_char do |char|
        if char == ',' && !current_part.match?(/£[\d.,]+$/)
          # Only split on commas that aren't part of a number
          ticket_parts << current_part.strip
          current_part = ''
        else
          current_part += char
        end
      end
      ticket_parts << current_part.strip if current_part.strip.length > 0

      # Initialize variables
      donation_amount = 0
      discount_percentage = 0
      fixed_discount = 0

      # Process each part (ticket, donation, discount)
      # Does not yet handle multiple % discounts (OK if no monthly donors) or credit
      ticket_types = []
      ticket_parts.each do |part|
        case part
        when /£[\d.,]+\s+donation(?!\s+to\s+Dandelion)/
          donation_amount = part.match(/£([\d.,]+)\s+donation/)[1].gsub(',', '').to_f
        when /(\d+)%\s*discount/
          discount_percentage = part.match(/(\d+)%\s*discount/)[1].to_f
        when /£[\d.,]+\s*discount/
          fixed_discount = part.match(/£([\d.,]+)\s*discount/)[1].gsub(',', '').to_f
        when /.*£[\d.,]+x\d+/
          ticket_types << part
        end
      end

      results = []

      # Create separate row for each ticket type
      ticket_types.each do |ticket_type|
        price, quantity = ticket_type.match(/£([\d.,]+)x(\d+)/)[1, 2].map { |n| n.gsub(',', '').to_f }
        ticket_row = row.to_h

        # Build discount text combining both types if present
        discount_texts = []
        if discount_percentage > 0
          formatted_percentage = discount_percentage.to_i == discount_percentage ? discount_percentage.to_i : discount_percentage
          discount_texts << "#{formatted_percentage}% discount"
        end
        if fixed_discount > 0
          formatted_fixed = fixed_discount.to_i == fixed_discount ? fixed_discount.to_i : fixed_discount
          formatted_fixed_with_commas = formatted_fixed.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
          discount_texts << "£#{formatted_fixed_with_commas} discount"
        end
        discount_text = discount_texts.empty? ? '' : ", #{discount_texts.join(', ')}"

        ticket_row['Description'] = "#{base_desc}: #{ticket_type}#{discount_text}"

        # Apply both discounts: first the percentage, then the fixed amount
        subtotal = price * quantity
        after_percentage = discount_percentage > 0 ? subtotal * (1 - (discount_percentage / 100)) : subtotal
        individual_amount = fixed_discount > 0 ? after_percentage - fixed_discount : after_percentage

        ticket_row['Amount'] = individual_amount.round(2).to_s
        results << ticket_row
      end

      # Only create donation row if there's a donation to the organisation
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
      processed_rows.compact.each do |row|
        output_csv << row.values
      end
    end
  end
end
