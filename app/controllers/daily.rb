Dandelion::App.controller do
  get '/daily', access: :public do
    @daily_path = '/daily'
    daily
  end

  get '/daily/:name', access: :public do
    @location = Location.find_by(name: params[:name]) || not_found
    @title = "#{@location.name} Daily"
    @daily_path = "/daily/#{@location.name}"
    daily
  end
end
