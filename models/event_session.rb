class EventSession
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  field :start_time, type: Time
  field :end_time, type: Time

  belongs_to_without_parent_validation :event, index: true

  validates_presence_of :start_time
  validates_presence_of :end_time

  before_validation do
    errors.add(:start_time, 'must be after event start time') if event && start_time && start_time < event.start_time
    errors.add(:end_time, 'must be before event end time') if event && end_time && end_time > event.end_time
    errors.add(:end_time, 'must be after the start time') if end_time && start_time && end_time <= start_time
  end

  def name
    "#{event.name}, session #{session_number}/#{total_sessions}"
  end

  def location
    event.location
  end

  def slug
    event.slug
  end

  def session_number
    event.event_sessions.and(:start_time.lte => start_time).count
  end

  def total_sessions
    event.event_sessions.count
  end

  def time_zone
    event.time_zone
  end

  def time_zone_or_default
    event.time_zone_or_default
  end

  def when_details(zone, with_zone: true)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && event.location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"
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
    z = "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      start_time.to_date
    else
      "#{start_time.to_date} – #{end_time.to_date} #{z if with_zone}"
    end
  end

  def ical(order: nil)
    event_session = self
    cal = Icalendar::Calendar.new
    cal.append_custom_property('METHOD', 'REQUEST') if order
    cal.event do |e|
      e.summary = (event_session.start_time.to_date == event_session.end_time.to_date ? event_session.name : "#{event_session.name} starts")
      e.dtstart = (event_session.start_time.to_date == event_session.end_time.to_date ? event_session.start_time.utc.strftime('%Y%m%dT%H%M%SZ') : Icalendar::Values::Date.new(event_session.start_time.to_date))
      e.dtend = (event_session.start_time.to_date == event_session.end_time.to_date ? event_session.end_time.utc.strftime('%Y%m%dT%H%M%SZ') : nil)
      e.transp = (event_session.start_time.to_date == event_session.end_time.to_date ? 'OPAQUE' : 'TRANSPARENT')
      e.location = event.location
      e.description = order ? %(#{ENV['BASE_URI']}/orders/#{order.id}) : %(#{ENV['BASE_URI']}/events/#{event.id})
      e.organizer = event.email
      e.uid = event_session.id.to_s
      if order
        e.status = 'CONFIRMED'
        e.attendee = Icalendar::Values::CalAddress.new(
          "mailto:#{order.account.email}",
          cn: order.account.email,
          role: 'REQ-PARTICIPANT',
          partstat: 'ACCEPTED',
          cutype: 'INDIVIDUAL'
        )
      end
    end
    cal
  end
end
