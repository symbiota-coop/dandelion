namespace :icons do
  task generate: :environment do
    # Create calendar directories if they don't exist
    calendar_dir = Padrino.root('app', 'assets', 'images', 'icons', 'calendar')
    svg_dir = File.join(calendar_dir, 'svg')
    png_dir = File.join(calendar_dir, 'png')
    FileUtils.mkdir_p(svg_dir) unless Dir.exist?(svg_dir)
    FileUtils.mkdir_p(png_dir) unless Dir.exist?(png_dir)

    # Create image icon directories if they don't exist
    image_dir = Padrino.root('app', 'assets', 'images', 'icons', 'image')
    FileUtils.mkdir_p(image_dir) unless Dir.exist?(image_dir)

    puts 'Generating calendar icons for all days of the year...'

    # Read the calendar template
    calendar_template_path = Padrino.root('app', 'views', 'icons', '_calendar.erb')
    calendar_template_content = File.read(calendar_template_path)

    # Month abbreviations
    months = %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC]
    days_in_month = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] # Feb has 29 for leap year

    calendar_svg_generated = 0
    calendar_png_converted = 0

    months.each_with_index do |month, month_index|
      days_in_month[month_index].times do |day_num|
        day = (day_num + 1).to_s

        # Skip invalid dates (like Feb 30)
        begin
          Date.new(2024, month_index + 1, day_num + 1)
        rescue ArgumentError
          next
        end

        # Generate filenames
        svg_filename = "#{month.downcase}_#{day.rjust(2, '0')}.svg"
        png_filename = "#{month.downcase}_#{day.rjust(2, '0')}.png"
        svg_filepath = File.join(svg_dir, svg_filename)
        png_filepath = File.join(png_dir, png_filename)

        # Generate SVG if it doesn't exist
        if File.exist?(svg_filepath)
          puts "Skipping #{svg_filename} (already exists)"
        else
          begin
            # Generate SVG content using ERB template
            erb = ERB.new(calendar_template_content)
            svg_content = erb.result(binding)

            # Save the SVG content
            File.write(svg_filepath, svg_content)
            puts "Generated #{svg_filename}"
            calendar_svg_generated += 1
          rescue StandardError => e
            puts "Error generating #{svg_filename}: #{e.message}"
            next
          end
        end

        # Convert to PNG if PNG doesn't exist
        if File.exist?(png_filepath)
          puts "Skipping #{png_filename} (already exists)"
        else
          begin
            # Convert SVG to PNG using rsvg-convert
            # --width 160 --height 160: Set output dimensions
            # --format png: Specify PNG output format
            # --background-color transparent: Keep transparent background
            system("rsvg-convert --width 160 --height 160 --format png --background-color white '#{svg_filepath}' > '#{png_filepath}'")

            if File.exist?(png_filepath)
              puts "Converted #{svg_filename} → #{png_filename}"
              calendar_png_converted += 1
            else
              puts "Failed to convert #{svg_filename}"
            end
          rescue StandardError => e
            puts "Error converting #{svg_filename}: #{e.message}"
          end
        end
      end
    end

    puts 'Calendar icon generation complete! 🗓️📸'
    puts "SVG files generated: #{calendar_svg_generated}"
    puts "PNG files converted: #{calendar_png_converted}"

    puts 'Generating image icons...'

    # Read the image template
    image_template_path = Padrino.root('app', 'views', 'icons', '_image.erb')
    image_template_content = File.read(image_template_path)

    # Icon types to generate
    icons = %w[geo-alt camera-video]

    image_svg_generated = 0
    image_png_converted = 0

    icons.each do |icon_name|
      # Generate filenames
      svg_filename = "image-#{icon_name}.svg"
      png_filename = "image-#{icon_name}.png"
      svg_filepath = File.join(image_dir, svg_filename)
      png_filepath = File.join(image_dir, png_filename)

      # Generate SVG if it doesn't exist
      if File.exist?(svg_filepath)
        puts "Skipping #{svg_filename} (already exists)"
      else
        begin
          # Generate SVG content using ERB template
          erb = ERB.new(image_template_content)
          image = icon_name # Set the image variable for the template
          svg_content = erb.result(binding)

          # Save the SVG content
          File.write(svg_filepath, svg_content)
          puts "Generated #{svg_filename}"
          image_svg_generated += 1
        rescue StandardError => e
          puts "Error generating #{svg_filename}: #{e.message}"
          next
        end
      end

      # Convert to PNG if PNG doesn't exist
      if File.exist?(png_filepath)
        puts "Skipping #{png_filename} (already exists)"
      else
        begin
          # Convert SVG to PNG using rsvg-convert
          # --width 160 --height 160: Set output dimensions
          # --format png: Specify PNG output format
          # --background-color transparent: Keep transparent background
          system("rsvg-convert --width 160 --height 160 --format png --background-color white '#{svg_filepath}' > '#{png_filepath}'")

          if File.exist?(png_filepath)
            puts "Converted #{svg_filename} → #{png_filename}"
            image_png_converted += 1
          else
            puts "Failed to convert #{svg_filename}"
          end
        rescue StandardError => e
          puts "Error converting #{svg_filename}: #{e.message}"
        end
      end
    end

    puts 'Image icon generation complete! 🖼️📸'
    puts "SVG files generated: #{image_svg_generated}"
    puts "PNG files converted: #{image_png_converted}"

    puts 'All icon generation complete! 🎨'
    puts "Total SVG files generated: #{calendar_svg_generated + image_svg_generated}"
    puts "Total PNG files converted: #{calendar_png_converted + image_png_converted}"
  end
end
