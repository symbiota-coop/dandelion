require 'active_support/core_ext/integer/inflections'

Time::DATE_FORMATS.merge!(
  default: ->(time) { time.to_fs(:date) + ', ' + time.to_fs(:time) },
  db_local: ->(time) { time.strftime('%Y-%m-%d %H:%M:%S') },
  date: ->(time) { time.to_date.to_s },
  no_year: ->(time) { time.to_date.to_fs(:no_year) + ', ' + time.to_fs(:time) },
  month_year: ->(time) { time.to_date.to_fs(:month_year) + ', ' + time.to_fs(:time) },
  time: ->(time) { time.strftime("#{(t = time.hour % 12) == 0 ? 12 : t}:%M#{time.strftime('%p').downcase}") },
  no_double_zeros: lambda { |time|
                     time.strftime("#{(t = time.hour % 12) == 0 ? 12 : t}#{time.strftime(':%M') unless time.strftime(':%M') == ':00'}#{time.strftime('%p').downcase}")
                   }
)

Date::DATE_FORMATS.merge!(
  default: ->(date) { date.strftime("%a #{date.day.ordinalize} %b %Y") },
  db_local: ->(date) { date.strftime('%Y-%m-%d') },
  no_year: ->(date) { date.strftime("%a #{date.day.ordinalize} %B") },
  no_year_concise: ->(date) { date.strftime("%a #{date.day.ordinalize} %b") },
  month_year: ->(date) { date.strftime('%b %Y') }
)

module ActiveSupport
  class TimeWithZone
    def to_s(format = :default)
      if (formatter = Time::DATE_FORMATS[format])
        if formatter.respond_to?(:call)
          formatter.call(self).to_s
        else
          strftime(formatter)
        end
      else
        to_default_s
      end
    end
  end
end

class Time
  def to_s(format = :default)
    if (formatter = Time::DATE_FORMATS[format])
      if formatter.respond_to?(:call)
        formatter.call(self).to_s
      else
        strftime(formatter)
      end
    else
      to_default_s
    end
  end
end

class Date
  def to_s(format = :default)
    if (formatter = Date::DATE_FORMATS[format])
      if formatter.respond_to?(:call)
        formatter.call(self).to_s
      else
        strftime(formatter)
      end
    else
      to_default_s
    end
  end
end
