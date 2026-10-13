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
    erb :daily
  end
end
