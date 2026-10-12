Dandelion::App.controller do
  get '/daily' do
    @date = if params[:date]
              begin
                Date.parse(params[:date])
              rescue Date::Error
                Date.today
              end
            else
              Date.today
            end
    if request.xhr?
      @edition = Daily.edition(@date)
      partial :daily
    else
      erb :daily
    end
  end
end
