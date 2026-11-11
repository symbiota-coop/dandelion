# When an event or event session runs, as text, in the given zone unless it's in person somewhere with a time zone of
# its own. Including models give start_time, end_time, location, time_zone and time_zone_or_default
module WhenDetails
  extend ActiveSupport::Concern

  def when_details(zone, with_zone: true)
    return unless start_time && end_time

    start_time, end_time, zone_label = zoned_times(zone)
    if start_time.to_date == end_time.to_date
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_fs(:no_double_zeros)} #{zone_label if with_zone}"
    else
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_date}, #{end_time.to_fs(:no_double_zeros)} #{zone_label if with_zone}"
    end
  end

  def concise_when_details(zone, with_zone: false)
    return unless start_time && end_time

    start_time, end_time, zone_label = zoned_times(zone)
    if start_time.to_date == end_time.to_date
      start_time.to_date
    else
      "#{start_time.to_date} – #{end_time.to_date}#{" #{zone_label}" if with_zone}"
    end
  end

  private

  def zoned_times(zone)
    zone ||= time_zone_or_default
    zone = time_zone if time_zone && location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    [start_time, end_time, "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"]
  end
end
