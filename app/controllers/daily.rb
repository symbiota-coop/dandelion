Dandelion::App.controller do
  get '/daily' do
    @date = params[:date] ? Date.parse(params[:date]) : Date.today
    if request.xhr?
      @event_tags = EventTag.all
      stash_partial(:daily, key: "/daily?date=#{@date.to_fs(:db_local)}")
    else
      erb :daily
    end
  end
end
