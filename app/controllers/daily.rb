Dandelion::App.controller do
  get '/daily' do
    @date = if params[:date]
              begin
                parsed_date = Date.parse(params[:date])
                # Validate date is within reasonable bounds to prevent overflow
                if parsed_date.year < 1900 || parsed_date.year > 2037
                  Date.today
                else
                  parsed_date
                end
              rescue Date::Error
                Date.today
              end
            else
              Date.today
            end
    if request.xhr?
      @event_tags = EventTag.all
      stash_partial(:daily, key: "/daily?date=#{@date.to_fs(:db_local)}")
    else
      erb :daily
    end
  end
end
