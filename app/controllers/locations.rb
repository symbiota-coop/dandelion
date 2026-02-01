Dandelion::App.controller do
  get '/near/:near' do
    halt 404 unless params[:near]
    params[:in_person] = true

    @events = Event.live.public.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil

    @events = apply_geo_filter(@events)
    @events = @events.future(@from)
    @events = @events.and(:start_time.lt => @to + 1) if @to

    if request.xhr?
      cp(:'locations/location', key: "/locations/#{params[:near]}")
    else
      erb :'locations/location'
    end
  end
end
