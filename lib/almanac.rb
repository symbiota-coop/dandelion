# Moon phase and Wheel of the Year (no external gems), for the header's moon and the Wheel of the Year page
# (app/assets/wheel-of-the-year.html, which loads wheel_of_the_year from /wheel-of-the-year.json).
# Moon: based on known new moon reference and synodic month length.
# Wheel: 8 sabbats (4 solar + 4 cross-quarter); solar dates use astronomical approximations.
module Almanac
  LUNAR_MONTH = 29.530588853
  KNOWN_NEW_MOON = Time.utc(2000, 1, 6, 6, 14, 0)

  PHASES = {
    0..1 => { name: 'New moon', icon: '🌑' },
    1..6.38 => { name: 'Waxing crescent', icon: '🌒' },
    6.38..8.38 => { name: 'First quarter', icon: '🌓' },
    8.38..13.76 => { name: 'Waxing gibbous', icon: '🌔' },
    13.76..15.76 => { name: 'Full moon', icon: '🌕' },
    15.76..21.14 => { name: 'Waning gibbous', icon: '🌖' },
    21.14..23.14 => { name: 'Last quarter', icon: '🌗' },
    23.14..LUNAR_MONTH => { name: 'Waning crescent', icon: '🌘' }
  }.freeze

  SOLAR_EVENT_COEFFICIENTS = {
    march_equinox: [2_451_623.80984, 365_242.37404, 0.05169, -0.00411, -0.00057],
    june_solstice: [2_451_716.56767, 365_241.62603, 0.00325, 0.00888, -0.00030],
    september_equinox: [2_451_810.21715, 365_242.01767, -0.11575, 0.00337, 0.00078],
    december_solstice: [2_451_900.05952, 365_242.74049, -0.06223, -0.00823, 0.00032]
  }.freeze

  def self.moon_age(time = Time.now)
    ((time.utc - KNOWN_NEW_MOON) / 86_400) % LUNAR_MONTH
  end

  def self.moon_phase(time = Time.now)
    lunar_age = moon_age(time)
    PHASES.find { |range, _| range.cover?(lunar_age) }&.last
  end

  def self.moon_name(time = Time.now)
    moon_phase(time)&.dig(:name)
  end

  def self.moon_icon(time = Time.now)
    moon_phase(time)&.dig(:icon)
  end

  def self.solar_jde(event, year)
    c0, c1, c2, c3, c4 = SOLAR_EVENT_COEFFICIENTS.fetch(event)
    t = (year - 2000) / 1000.0
    c0 + (c1 * t) + (c2 * (t**2)) + (c3 * (t**3)) + (c4 * (t**4))
  end

  # The festivals in order round the wheel from Yule: the solar ones with their solstice or equinox in each hemisphere,
  # and the cross-quarter days with their traditional dates
  FESTIVALS = [
    { id: 'yule', name: 'Yule', north: :december_solstice, south: :june_solstice },
    { id: 'imbolc', name: 'Imbolc', traditional: { north: '1st–2nd February', south: '1st–2nd August' } },
    { id: 'ostara', name: 'Ostara', north: :march_equinox, south: :september_equinox },
    { id: 'beltane', name: 'Beltane', traditional: { north: '1st May', south: '31st October – 1st November' } },
    { id: 'litha', name: 'Litha', north: :june_solstice, south: :december_solstice },
    { id: 'lughnasadh', name: 'Lughnasadh', traditional: { north: '1st August', south: '1st February' } },
    { id: 'mabon', name: 'Mabon', north: :september_equinox, south: :march_equinox },
    { id: 'samhain', name: 'Samhain', traditional: { north: '31st October', south: '30th April – 1st May' } }
  ].freeze

  # A traditional date's first day in a year: '31st October – 1st November' is 31 October
  def self.traditional_date(text, year)
    Date.new(year, Date::MONTHNAMES.index(text[/[A-Z][a-z]+/]), text[/\d+/].to_i)
  end

  # A Julian Day counts from noon UTC, and the Unix epoch is JD 2440587.5
  def self.solar_time(event, year)
    Time.at((solar_jde(event, year) - 2_440_587.5) * 86_400).utc
  end

  # Every festival in the given years, in order, with the date it's kept. A solar festival is kept on its solstice or
  # equinox (at), a cross-quarter day on its traditional date, with its astronomical midpoint between the solstices and
  # equinoxes either side of it (at)
  def self.festival_timeline(years, hemisphere: :north)
    solar = years.flat_map do |year|
      FESTIVALS.each_with_index.filter_map { |festival, i| [i, solar_time(festival[hemisphere], year)] if festival[hemisphere] }
    end.sort_by(&:last)

    solar.each_with_index.flat_map do |(i, at), n|
      entries = [{ festival: FESTIVALS[i], at: at, date: at.to_date }]
      if (following = solar[n + 1])
        cross = FESTIVALS[(i + 1) % FESTIVALS.size]
        midpoint = Time.at((at.to_r + following.last.to_r) / 2).utc
        entries << { festival: cross, at: midpoint, date: traditional_date(cross[:traditional][hemisphere], midpoint.year) }
      end
      entries
    end
  end

  def self.next_sabbat(date = Date.today)
    today = date.is_a?(Date) ? date : date.to_date
    entry = festival_timeline((today.year - 1)..(today.year + 1)).find { |e| e[:date] >= today }
    [entry[:date], entry[:festival]]
  end

  def self.days_until_next_sabbat(date = Date.today)
    sabbat_date, sabbat = next_sabbat(date)
    today = date.is_a?(Date) ? date : date.to_date
    [(sabbat_date - today).to_i, sabbat[:name]]
  end

  # What the Wheel of the Year page shows: the festivals, in order, with their names and traditional dates; each one
  # from two years back to two years on in each hemisphere, with its solstice, equinox or midpoint (at), which the page
  # turns into dates in the viewer's timezone, and a cross-quarter day's traditional date (date)
  def self.wheel_of_the_year(time = Time.now)
    years = (time.year - 2)..(time.year + 2)
    {
      festivals: FESTIVALS.map { |festival| festival.slice(:id, :name, :traditional) },
      timeline: %i[north south].to_h do |hemisphere|
        [hemisphere, festival_timeline(years, hemisphere: hemisphere).map do |e|
          { id: e[:festival][:id], at: e[:at].iso8601, date: (e[:date].iso8601 if e[:festival][:traditional]) }.compact
        end]
      end
    }
  end
end
