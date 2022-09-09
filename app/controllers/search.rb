Dandelion::App.controller do
  get '/search' do
    sign_in_required!
    if request.xhr?
      @q = params[:term]
      halt if @q.nil? || @q.length < 3

      results = []

      @gatherings = Gathering.and(name: /#{::Regexp.escape(@q)}/i).and(listed: true).and(:privacy.ne => 'secret')
      results += @gatherings.limit(10).map { |gathering| { label: %(<i class="fa fa-fw fa-moon"></i> #{gathering.name}), value: %(gathering:"#{gathering.name}") } }

      @places = Place.and(name: /#{::Regexp.escape(@q)}/i)
      results += @places.limit(10).map { |place| { label: %(<i class="fa fa-fw fa-map"></i> #{place.name}), value: %(place:"#{place.name}") } }

      @organisations = Organisation.and(name: /#{::Regexp.escape(@q)}/i)
      results += @organisations.limit(10).map { |organisation| { label: %(<i class="fa fa-fw fa-flag"></i> #{organisation.name}), value: %(organisation:"#{organisation.name}") } }

      @events = Event.live.public.legit.future.and(:id.in => Event.all.or(
        { name: /#{::Regexp.escape(@q)}/i },
        { description: /#{::Regexp.escape(@q)}/i }
      ).pluck(:id))
      results += @events.limit(10).map { |event| { label: %(<i class="fa fa-fw fa-calendar"></i> #{event.name}), value: %(event:"#{event.name}") } }

      @accounts = Account.public
      @accounts = @accounts.and(:id.in => Account.all.or(
        { name: /#{::Regexp.escape(@q)}/i },
        { name_transliterated: /#{::Regexp.escape(@q)}/i },
        { email: /#{::Regexp.escape(@q)}/i },
        { username: /#{::Regexp.escape(@q)}/i }
      ).pluck(:id))
      results += @accounts.limit(10).map { |account| { label: %(<i class="fa fa-fw fa-user"></i> #{account.name}), value: %(account:"#{account.name}") } }

      results.to_json
    else
      @type = params[:type] || 'events'
      if (@q = params[:q])
        %w[gathering place organisation event account].each do |t|
          if @q.starts_with?("#{t}:")
            @q = @q.match(/#{t}:"(.+)"/)[1]
            @type = t.pluralize
          end
        end
        case @type
        when 'gatherings'
          @gatherings = Gathering.and(name: /#{::Regexp.escape(@q)}/i).and(listed: true).and(:privacy.ne => 'secret')
          @gatherings = @gatherings.paginate(page: params[:page], per_page: 10).order('name asc')
          redirect "/g/#{@gatherings.first.slug}" if @gatherings.count == 1
        when 'places'
          @places = Place.and(name: /#{::Regexp.escape(@q)}/i)
          @places = @places.paginate(page: params[:page], per_page: 10).order('name asc')
          redirect "/places/#{@places.first.id}" if @places.count == 1
        when 'organisations'
          @organisations = Organisation.and(name: /#{::Regexp.escape(@q)}/i)
          @organisations = @organisations.paginate(page: params[:page], per_page: 10).order('name asc')
          redirect "/o/#{@organisations.first.slug}" if @organisations.count == 1
        when 'events'
          @events = Event.live.public.legit.future.and(:id.in => Event.all.or(
            { name: /#{::Regexp.escape(@q)}/i },
            { description: /#{::Regexp.escape(@q)}/i }
          ).pluck(:id))
          @events = @events.paginate(page: params[:page], per_page: 10).order('start_time asc')
          redirect "/events/#{@events.first.id}" if @events.count == 1
        when 'accounts'
          @accounts = Account.public
          @accounts = @accounts.and(:id.in => Account.all.or(
            { name: /#{::Regexp.escape(@q)}/i },
            { name_transliterated: /#{::Regexp.escape(@q)}/i },
            { email: /#{::Regexp.escape(@q)}/i },
            { username: /#{::Regexp.escape(@q)}/i }
          ).pluck(:id))
          @accounts = @accounts.paginate(page: params[:page], per_page: 10).order('last_active desc')
          redirect "/u/#{@accounts.first.username}" if @accounts.count == 1
        end
      end
      erb :search
    end
  end
end
