namespace :icons do
  task generate: :environment do
    # Create calendar directories if they don't exist
    calendar_dir = Padrino.root('app', 'assets', 'images', 'icons', 'calendar')
    svg_dir = File.join(calendar_dir, 'svg')
    png_dir = File.join(calendar_dir, 'png')
    FileUtils.mkdir_p(svg_dir)
    FileUtils.mkdir_p(png_dir)

    # Create image icon directories if they don't exist
    image_dir = Padrino.root('app', 'assets', 'images', 'icons', 'image')
    FileUtils.mkdir_p(image_dir)

    puts 'Generating calendar icons for all days of the year...'

    # Read the calendar template
    calendar_template_path = Padrino.root('app', 'views', 'icons', '_calendar.erb')
    calendar_template_content = File.read(calendar_template_path)

    # Color schemes for calendar icons: emails use green for the default theme and greyscale for events and
    # organisations with their own, since the PNGs can't take any colour. Green is the default theme's 50 and 800,
    # as on the site's date tile; greyscale is --bs-gray-200 and 800
    color_schemes = {
      green: {
        month_bg_color: '#e9fbed',
        month_text_color: '#006f2a',
        day_text_color: '#000000'
      },
      greyscale: {
        month_bg_color: '#ecebea',
        month_text_color: '#3a3938',
        day_text_color: '#000000'
      }
    }

    # Get month abbreviations and days dynamically from Ruby
    months = (1..12).map { |m| Date::ABBR_MONTHNAMES[m].upcase }
    days_in_month = (1..12).map { |m| Date.new(2024, m, -1).day } # Get last day of each month

    total_calendar_svg_generated = 0
    total_calendar_png_converted = 0

    # Generate icons for each color scheme
    color_schemes.each do |scheme_name, colors|
      puts "\nGenerating #{scheme_name} calendar icons..."

      # Create scheme-specific directories
      scheme_svg_dir = File.join(svg_dir, scheme_name.to_s)
      scheme_png_dir = File.join(png_dir, scheme_name.to_s)
      FileUtils.mkdir_p(scheme_svg_dir)
      FileUtils.mkdir_p(scheme_png_dir)

      # Set color variables for this scheme
      month_bg_color = colors[:month_bg_color]
      month_text_color = colors[:month_text_color]
      day_text_color = colors[:day_text_color]

      calendar_svg_generated = 0
      calendar_png_converted = 0

      months.each_with_index do |month, month_index|
        days_in_month[month_index].times do |day_num|
          day = (day_num + 1).to_s

          # Generate filenames
          svg_filename = "#{month.downcase}_#{day.rjust(2, '0')}.svg"
          png_filename = "#{month.downcase}_#{day.rjust(2, '0')}.png"
          svg_filepath = File.join(scheme_svg_dir, svg_filename)
          png_filepath = File.join(scheme_png_dir, png_filename)

          # Generate SVG if it doesn't exist
          if File.exist?(svg_filepath)
            puts "Skipping #{scheme_name}/#{svg_filename} (already exists)"
          else
            begin
              # Generate SVG content using ERB template
              erb = ERB.new(calendar_template_content)
              svg_content = erb.result(binding)

              # Save the SVG content
              File.write(svg_filepath, svg_content)
              puts "Generated #{scheme_name}/#{svg_filename}"
              calendar_svg_generated += 1
            rescue StandardError => e
              puts "Error generating #{scheme_name}/#{svg_filename}: #{e.message}"
              next
            end
          end

          # Convert to PNG if PNG doesn't exist
          if File.exist?(png_filepath)
            puts "Skipping #{scheme_name}/#{png_filename} (already exists)"
          else
            begin
              # Convert SVG to PNG using rsvg-convert
              # --width 160 --height 160: Set output dimensions
              # --format png: Specify PNG output format
              # --background-color white: Set white background
              system("rsvg-convert --width 160 --height 160 --format png --background-color white '#{svg_filepath}' > '#{png_filepath}'")

              if File.exist?(png_filepath)
                puts "Converted #{scheme_name}/#{svg_filename} → #{scheme_name}/#{png_filename}"
                calendar_png_converted += 1
              else
                puts "Failed to convert #{scheme_name}/#{svg_filename}"
              end
            rescue StandardError => e
              puts "Error converting #{scheme_name}/#{svg_filename}: #{e.message}"
            end
          end
        end
      end

      puts "#{scheme_name.capitalize} calendar icons: #{calendar_svg_generated} SVG, #{calendar_png_converted} PNG"
      total_calendar_svg_generated += calendar_svg_generated
      total_calendar_png_converted += calendar_png_converted
    end

    puts "\nCalendar icon generation complete! 🗓️📸"
    puts "Total SVG files generated: #{total_calendar_svg_generated}"
    puts "Total PNG files converted: #{total_calendar_png_converted}"

    puts 'Generating image icons...'

    # Read the image template
    image_template_path = Padrino.root('app', 'views', 'icons', '_image.erb')
    image_template_content = File.read(image_template_path)

    # Icon types to generate
    icons = %w[geo-alt camera-video]

    image_svg_generated = 0
    image_png_converted = 0

    # The image tiles carry no theme colour, so green and greyscale are the same; emails pick the directory as for the calendar
    color_schemes.each_key do |scheme_name|
      scheme_image_dir = File.join(image_dir, scheme_name.to_s)
      FileUtils.mkdir_p(scheme_image_dir)

      icons.each do |icon_name|
        # Generate filenames
        svg_filename = "image-#{icon_name}.svg"
        png_filename = "image-#{icon_name}.png"
        svg_filepath = File.join(scheme_image_dir, svg_filename)
        png_filepath = File.join(scheme_image_dir, png_filename)

        # Generate SVG if it doesn't exist
        if File.exist?(svg_filepath)
          puts "Skipping #{scheme_name}/#{svg_filename} (already exists)"
        else
          begin
            # Generate SVG content using ERB template
            erb = ERB.new(image_template_content)
            image = icon_name # Set the image variable for the template
            svg_content = erb.result(binding)

            # Save the SVG content
            File.write(svg_filepath, svg_content)
            puts "Generated #{scheme_name}/#{svg_filename}"
            image_svg_generated += 1
          rescue StandardError => e
            puts "Error generating #{scheme_name}/#{svg_filename}: #{e.message}"
            next
          end
        end

        # Convert to PNG if PNG doesn't exist
        if File.exist?(png_filepath)
          puts "Skipping #{scheme_name}/#{png_filename} (already exists)"
        else
          begin
            # Convert SVG to PNG using rsvg-convert
            # --width 160 --height 160: Set output dimensions
            # --format png: Specify PNG output format
            # --background-color white: Set white background
            system("rsvg-convert --width 160 --height 160 --format png --background-color white '#{svg_filepath}' > '#{png_filepath}'")

            if File.exist?(png_filepath)
              puts "Converted #{scheme_name}/#{svg_filename} → #{scheme_name}/#{png_filename}"
              image_png_converted += 1
            else
              puts "Failed to convert #{scheme_name}/#{svg_filename}"
            end
          rescue StandardError => e
            puts "Error converting #{scheme_name}/#{svg_filename}: #{e.message}"
          end
        end
      end
    end

    puts 'Image icon generation complete! 🖼️📸'
    puts "SVG files generated: #{image_svg_generated}"
    puts "PNG files converted: #{image_png_converted}"

    puts "\nAll icon generation complete! 🎨"
    puts "Total SVG files generated: #{total_calendar_svg_generated + image_svg_generated}"
    puts "Total PNG files converted: #{total_calendar_png_converted + image_png_converted}"
  end
end
