Dandelion::App.helpers do
  def concise_when_details(whenable, with_zone: false)
    whenable.send(:concise_when_details, current_account ? current_account.time_zone : session[:time_zone], with_zone: with_zone)
  end

  def when_details(whenable, with_zone: true)
    whenable.send(:when_details, current_account ? current_account.time_zone : session[:time_zone], with_zone: with_zone)
  end

  def event_viewer_timezone_query(event)
    return if event.time_zone && event.location != 'Online'

    tz = current_account ? current_account.time_zone : session[:time_zone]
    "&timezone=#{tz}" if tz
  end

  def parse_date(date)
    Date.parse(date)
  rescue Date::Error
    nil
  end
end
