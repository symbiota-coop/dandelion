require 'active_support/core_ext/integer/inflections'

Time::DATE_FORMATS.merge!(
  default: ->(time) { time.to_fs(:date) + ', ' + time.to_fs(:time) },
  date: ->(time) { time.to_date.to_s },
  no_year: ->(time) { time.to_date.to_fs(:no_year) + ', ' + time.to_fs(:time) },
  time: ->(time) { time.strftime("#{(t = time.hour % 12) == 0 ? 12 : t}:%M#{time.strftime('%p').downcase}") },
  no_double_zeros: lambda { |time|
                     time.strftime("#{(t = time.hour % 12) == 0 ? 12 : t}#{time.strftime(':%M') unless time.strftime(':%M') == ':00'}#{time.strftime('%p').downcase}")
                   }
)

Date::DATE_FORMATS.merge!(
  default: ->(date) { date.strftime("%a #{date.day.ordinalize} %b %Y") },
  no_year: ->(date) { date.strftime("%a #{date.day.ordinalize} %B") }
)

module ActiveSupport
  class TimeWithZone
    def to_s(format = :default)
      if formatter = Time::DATE_FORMATS[format]
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
    if formatter = Time::DATE_FORMATS[format]
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
    if formatter = Date::DATE_FORMATS[format]
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

