Dandelion::App.helpers do
  # The Daily for the date in params, or the latest: the main one, or @location's
  def daily
    # A date that won't parse (Date::Error, or ArgumentError when it's too long; TypeError for date[]=) gets the latest
    @date = begin
      Date.parse(params[:date]) if params[:date]
    rescue ArgumentError, TypeError
      nil
    end || Daily.latest_date(location: @location) || Date.today
    @edition = Daily.edition(@date, location: @location)
    unless @edition
      # Past dates with no edition don't exist, so crawlers drop them; future ones will, so just keep them out of search
      if @date < Date.today
        status 404
        @own_not_found_page = true
      elsif @date > Date.today
        response.headers['X-Robots-Tag'] = 'noindex'
      end
    end
    erb :daily
  end
end
