Dandelion::App.controller do
  get '/daily' do
    @date = params[:date] ? Date.parse(params[:date]) : Date.today
    if request.xhr?
      @event_tags = EventTag.all
      cp(:daily, key: '/daily', expires: 1.day.from_now)
    else
      erb :daily
    end
  end
end
