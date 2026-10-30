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

  # Where location editions were first
  get '/locations/:name/daily' do
    redirect "/daily/#{ERB::Util.url_encode(params[:name])}#{"?date=#{ERB::Util.url_encode(params[:date])}" if params[:date]}", 301
  end
end
