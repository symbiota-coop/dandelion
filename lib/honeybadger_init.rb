Honeybadger.configure do |config|
  config.before_notify do |notice|
    error_type = notice.exception.class.name
    error_message = notice.error_message

    should_ignore = [
      %w[Sinatra::NotFound SignalException].include?(error_type),
      error_type == 'Sinatra::BadRequest' && error_message && error_message.include?('invalid %-encoding'),
      error_type == 'Sinatra::BadRequest' && error_message && error_message.include?('Invalid multipart/form-data: EOFError'),
      error_type == 'ThreadError' && error_message && error_message.include?("can't be called from trap context"),
      error_type == 'Mongoid::Errors::Validations' && error_message && error_message.include?('Ticket type is full'),
      error_type == 'Errno::EIO' && error_message && error_message.include?('Input/output error'),
      error_type == 'Encoding::CompatibilityError' && error_message && error_message.include?('invalid byte sequence in UTF-8')
    ].any?

    notice.halt! if should_ignore
  end
end
