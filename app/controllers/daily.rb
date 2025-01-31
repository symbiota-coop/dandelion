Dandelion::App.controller do
  get '/daily' do
    if request.xhr?
      cp(:daily, key: '/daily', expires: 1.day.from_now)
    else
      erb :daily
    end
  end
end
