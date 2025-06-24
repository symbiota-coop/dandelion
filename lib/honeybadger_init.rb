Honeybadger.configure do |config|
  config.before_notify do |notice|
    notice.halt! if notice.error_message =~ /Ticket type is full/
  end
end
