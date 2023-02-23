Dandelion::App.controller do
  get '/search' do
    if request.xhr?
      @q = params[:term]
      halt if @q.nil? || @q.length < 3

      results = []

      results += search(Event, Event.live.public.legit.future(1.month.ago), @q, 5).map do |event|
        { label: %(<i class="fa fa-fw fa-calendar"></i> #{event.name} (#{concise_when_details(event)})), value: %(event:"#{event.name}") }
      end

      results += search(Account, Account.public, @q, 5).map do |account|
        { label: %(<i class="fa fa-fw fa-user"></i> #{account.name}), value: %(account:"#{account.name}") }
      end

      results += search(Organisation, Organisation.all, @q, 5).map do |organisation|
        { label: %(<i class="fa fa-fw fa-flag"></i> #{organisation.name}), value: %(organisation:"#{organisation.name}") }
      end

      results += search(Gathering, Gathering.and(listed: true).and(:privacy.ne => 'secret'), @q, 5).map do |gathering|
        { label: %(<i class="fa fa-fw fa-moon"></i> #{gathering.name}), value: %(gathering:"#{gathering.name}") }
      end

      results += search(Place, Place.all, @q, 5).map do |place|
        { label: %(<i class="fa fa-fw fa-map"></i> #{place.name}), value: %(place:"#{place.name}") }
      end

      results.to_json
    else
      @type = params[:type] || 'events'
      if (@q = params[:q])
        %w[gathering place organisation event account].each do |t|
          if params[:q].starts_with?("#{t}:")
            @q = @q.match(/#{t}:"(.+)"/)[1]
            @type = t.pluralize
          end
        end
        case @type
        when 'events'
          @events = search(Event, Event.live.public.legit.future(1.month.ago), @q, 25)
        when 'accounts'
          @accounts = search(Account, Account.public, @q, 25)
        when 'organisations'
          @organisations = search(Organisation, Organisation.all, @q, 25)
        when 'gatherings'
          @gatherings = search(Gathering, Gathering.and(listed: true).and(:privacy.ne => 'secret'), @q, 25)
        when 'places'
          @places = search(Place, Place.all, @q, 25)
        end
      end

      %w[gathering place organisation event account].each do |t|
        next unless params[:q] && params[:q].starts_with?("#{t}:")

        case t
        when 'gathering' then redirect "/g/#{@gatherings.first.slug}" if @gatherings.count == 1
        when 'place' then redirect "/places/#{@places.first.id}" if @places.count == 1
        when 'organisation' then redirect "/o/#{@organisations.first.slug}" if @organisations.count == 1
        when 'event' then redirect "/events/#{@events.first.id}" if @events.count == 1
        when 'account' then redirect "/u/#{@accounts.first.username}" if @accounts.count == 1
        end
      end

      erb :search
    end
  end
end
