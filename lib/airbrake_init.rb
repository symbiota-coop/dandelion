Airbrake.configure do |config|
  config.host = (ENV['AIRBRAKE_HOST'] or 'airbrake.io')
  config.project_id = (ENV['AIRBRAKE_PROJECT_ID'] or 1)
  config.project_key = (ENV['AIRBRAKE_PROJECT_KEY'] or ENV['AIRBRAKE_API_KEY'] or 'project_key')
  config.environment = Padrino.env
end

Airbrake.add_filter do |notice|
  should_ignore = notice[:errors].any? do |error|
    [
      %w[Sinatra::NotFound SignalException].include?(error[:type]),
      error[:type] == 'ArgumentError' && error[:message] && error[:message].include?('invalid %-encoding'),
      error[:type] == 'ThreadError' && error[:message] && error[:message].include?("can't be called from trap context"),
      error[:type] == 'Mongoid::Errors::Validations' && error[:message] && error[:message].include?('Ticket type is full'),
      error[:type] == 'Errno::EIO' && error[:message] && error[:message].include?('Input/output error')
    ].any?
  end

  notice.ignore! if should_ignore
end
