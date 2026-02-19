# Moon phase and Wheel of the Year (no external gems).
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

  def self.jde_to_date(jde)
    DateTime.jd(jde).to_date
  end

  def self.midpoint_date(jde_a, jde_b)
    jde_to_date((jde_a + jde_b) / 2.0)
  end

  def self.sabbats_for_year(year)
    yule_previous_jde = solar_jde(:december_solstice, year - 1)
    ostara_jde = solar_jde(:march_equinox, year)
    litha_jde = solar_jde(:june_solstice, year)
    mabon_jde = solar_jde(:september_equinox, year)
    yule_jde = solar_jde(:december_solstice, year)

    [
      { name: 'Imbolc', date: midpoint_date(yule_previous_jde, ostara_jde), solar: false },
      { name: 'Ostara', date: jde_to_date(ostara_jde), solar: true },
      { name: 'Beltane', date: midpoint_date(ostara_jde, litha_jde), solar: false },
      { name: 'Litha', date: jde_to_date(litha_jde), solar: true },
      { name: 'Lammas', date: midpoint_date(litha_jde, mabon_jde), solar: false },
      { name: 'Mabon', date: jde_to_date(mabon_jde), solar: true },
      { name: 'Samhain', date: midpoint_date(mabon_jde, yule_jde), solar: false },
      { name: 'Yule', date: jde_to_date(yule_jde), solar: true }
    ]
  end

  def self.next_sabbat(date = Date.today)
    today = date.is_a?(Date) ? date : date.to_date
    year = today.year

    all_dates = [year, year + 1].flat_map do |y|
      sabbats_for_year(y).map { |sabbat| [sabbat[:date], sabbat] }
    end

    all_dates.select { |d, _| d >= today }.min_by { |d, _| d }
  end

  def self.days_until_next_sabbat(date = Date.today)
    sabbat_date, sabbat = next_sabbat(date)
    today = date.is_a?(Date) ? date : date.to_date
    [(sabbat_date - today).to_i, sabbat[:name]]
  end
end
