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
      stash_partial(:daily, key: "/daily?date=#{@date.to_fs(:db_local)}")
    else
      erb :daily
    end
  end
end
