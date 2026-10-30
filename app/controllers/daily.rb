Dandelion::App.controller do
  get '/daily' do
    @daily_path = '/daily'
    daily
  end

  get '/daily/:name' do
    @location = Location.find_by(name: params[:name]) || not_found
    @title = "#{@location.name} Daily"
    @daily_path = "/daily/#{@location.name}"
    daily
  end
end
