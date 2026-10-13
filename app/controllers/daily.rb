Dandelion::App.controller do
  get '/daily' do
    @date = if params[:date]
              begin
                Date.parse(params[:date])
              rescue Date::Error
                Date.today
              end
            else
              Daily.latest_date || Date.today
            end
    @edition = Daily.edition(@date)
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
