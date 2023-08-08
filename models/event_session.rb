class EventSession
  include Mongoid::Document
  include Mongoid::Timestamps

  field :start_time, type: Time
  field :end_time, type: Time

  belongs_to :event, index: true

  validates_presence_of :start_time
  validates_presence_of :end_time

  before_validation do
    errors.add(:start_time, 'must be after event start time') if event && start_time && start_time < event.start_time
    errors.add(:end_time, 'must be before event end time') if event && end_time && end_time > event.end_time
    errors.add(:end_time, 'must be after the start time') if end_time && start_time && end_time <= start_time
  end

  def time_zone
    event.time_zone
  end

  def time_zone_or_default
    time_zone || ENV['DEFAULT_TIME_ZONE']
  end

  def when_details(zone, with_zone: true)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && event.location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{zone.include?('London') ? 'UK time' : zone.gsub('_', ' ')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_fs(:no_double_zeros)} #{z if with_zone}"
    else
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_date}, #{end_time.to_fs(:no_double_zeros)} #{z if with_zone}"
    end
  end

  def concise_when_details(zone, with_zone: false)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && event.location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{zone.include?('London') ? 'UK time' : zone.gsub('_', ' ')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      start_time.to_date
    else
      "#{start_time.to_date} – #{end_time.to_date} #{z if with_zone}"
    end
  end
end
