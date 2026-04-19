# Nearest populated place from GeoNames "cities" export (lat/lon → city name).
# Data: data/geonames/cities15000.txt (GeoNames export; update that file when refreshing upstream data).
# License: CC-BY 4.0 GeoNames — https://www.geonames.org/

class GeonamesCityLookup
  DEFAULT_RELATIVE_PATH = File.join('data', 'geonames', 'cities15000.txt').freeze
  # Beyond this, the "nearest" label is usually not meaningful for a venue pin.
  MAX_DISTANCE_KM = 250
  # Nearest point by distance is often a suburb (e.g. Solna vs Stockholm). Among places about as
  # close as that nearest hit, prefer the largest population so the label matches the metro name.
  METRO_PREFERENCE_MARGIN_KM = 25

  MUTEX = Mutex.new

  class << self
    def reset!
      MUTEX.synchronize { @rows = nil }
    end

    def nearest_city_name(lat, lon)
      return unless available?

      rows = cached_rows
      return if rows.blank?

      candidates = []
      rows.each do |row|
        km = haversine_km(lat, lon, row[:lat], row[:lon])
        next if km > MAX_DISTANCE_KM

        candidates << [row, km]
      end
      return if candidates.empty?

      min_km = candidates.map(&:last).min
      band = candidates.select { |_row, km| km <= min_km + METRO_PREFERENCE_MARGIN_KM }

      best_row, = band.max_by do |row, km|
        pop = row[:population].to_i
        score = (pop + 1) / (km + 1.0)
        [score, -km]
      end

      best_row[:name].to_s.strip.presence
    rescue StandardError
      nil
    end

    def available?
      File.file?(resolved_path)
    end

    def resolved_path
      custom = ENV['GEONAMES_CITIES_PATH'].to_s.strip
      return custom if custom.present?

      File.join(Padrino.root, DEFAULT_RELATIVE_PATH)
    end

    private

    def cached_rows
      MUTEX.synchronize do
        return @rows unless @rows.nil?

        @rows = load_rows
      end
    rescue StandardError
      @rows = []
    end

    def load_rows
      path = resolved_path
      rows = []
      File.open(path, 'r:UTF-8') do |f|
        f.each_line do |line|
          parts = line.split("\t")
          next if parts.size < 15

          # Column 7 = feature code (see geonames.org/export/codes.html). Skip PPLX (borough/district);
          # those points are often closer than the parent city and produce labels like "Treptow" vs "Berlin".
          next if parts[7].to_s == 'PPLX'

          lat = Float(parts[4])
          lon = Float(parts[5])
          name = parts[1].to_s
          next if name.blank?

          population = parts[14].to_s.strip.to_i
          rows << { lat: lat, lon: lon, name: name, population: population }
        rescue ArgumentError, TypeError
          next
        end
      end
      rows
    end

    # Earth radius 6371 km (WGS84)
    def haversine_km(lat1, lon1, lat2, lon2)
      r = 6371.0
      p1 = lat1 * Math::PI / 180
      p2 = lat2 * Math::PI / 180
      d_lat = (lat2 - lat1) * Math::PI / 180
      d_lon = (lon2 - lon1) * Math::PI / 180
      a = (Math.sin(d_lat / 2)**2) + (Math.cos(p1) * Math.cos(p2) * (Math.sin(d_lon / 2)**2))
      2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end
  end
end
