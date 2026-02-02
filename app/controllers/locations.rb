Dandelion::App.controller do
  get '/locations/:name' do
    @location = Location.find_by(name: params[:name]) || not_found

    params[:near] = @location.query

    @title = "Events near #{@location.name}"

    @events = Event.live.public.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil

    @events = apply_geo_filter(@events)
    @events = @events.future(@from)
    @events = @events.and(:start_time.lt => @to + 1) if @to

    if request.xhr?
      cp(:'locations/location', key: "/locations/#{@location.name}", expires: 1.day.from_now)
    else
      erb :'locations/location'
    end
  end
end
