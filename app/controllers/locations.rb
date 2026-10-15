Dandelion::App.controller do
  get '/locations/:name' do
    @location = Location.find_by(name: params[:name]) || not_found

    @title = @location.name
    params[:near] = @location.query
    params[:online] = true if @location.online?

    @events = Event.live.publicly_visible.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil

    @events = if @location.online?
                @events.online
              else
                apply_geo_filter(@events)
              end
    @events = @events.future(@from)
    @events = @events.and(:start_time.lt => @to + 1) if @to

    erb :'locations/location'
  end
end
