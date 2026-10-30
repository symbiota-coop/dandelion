Dandelion::App.controller do
  get '/daily' do
    @daily_path = '/daily'
    daily
  end

  get '/locations/:name/daily' do
    @location = Location.find_by(name: params[:name]) || not_found
    @title = "#{@location.name} Daily"
    @daily_path = "/locations/#{@location.name}/daily"
    daily
  end
end
