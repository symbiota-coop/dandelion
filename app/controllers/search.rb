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
          if params[:q] && params[:q].starts_with?('event:')
            @events = Event.live.public.legit.future(1.month.ago).and(name: @q)
            redirect "/events/#{@events.first.id}" if @events.count == 1
          end
          @events = search(Event, Event.live.public.legit.future(1.month.ago), @q, 25)
        when 'accounts'
          if params[:q] && params[:q].starts_with?('account:')
            @accounts = Account.public.and(name: @q)
            redirect "/u/#{@accounts.first.username}" if @accounts.count == 1
          end
          @accounts = search(Account, Account.public, @q, 25)
        when 'organisations'
          if params[:q] && params[:q].starts_with?('organisation:')
            @organisations = Organisation.and(name: @q)
            redirect "/o/#{@organisations.first.slug}" if @organisations.count == 1
          end
          @organisations = search(Organisation, Organisation.all, @q, 25)
        when 'gatherings'
          if params[:q] && params[:q].starts_with?('gathering:')
            @gatherings = Gathering.all.and(listed: true).and(:privacy.ne => 'secret').and(name: @q)
            redirect "/g/#{@gatherings.first.slug}" if @gatherings.count == 1
          end
          @gatherings = search(Gathering, Gathering.and(listed: true).and(:privacy.ne => 'secret'), @q, 25)
        when 'places'
          if params[:q] && params[:q].starts_with?('place:')
            @places = Place.all.and(name: @q)
            redirect "/places/#{@places.first.id}" if @places.count == 1
          end
          @places = search(Place, Place.all, @q, 25)
        end
      end

      erb :search
    end
  end
end
