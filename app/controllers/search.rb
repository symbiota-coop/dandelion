Dandelion::App.controller do
  get '/search' do
    if request.xhr?
      @q = params[:term]
      halt if @q.nil? || @q.length < 3

      results = []

      pipeline = [{
        '$search': {
          index: 'events',
          text: {
            query: @q,
            path: {
              wildcard: '*'
            }
          }
        }
      }]
      @events = Event.live.public.legit.future(1.month.ago).and(:id.in => Event.collection.aggregate(pipeline).pluck(:_id).map(&:to_s))

      # @accounts = Account.public
      # @accounts = @accounts.and(:id.in => Account.all.or(
      #   { name: /#{::Regexp.escape(@q)}/i },
      #   { name_transliterated: /#{::Regexp.escape(@q)}/i },
      #   { email: /#{::Regexp.escape(@q)}/i },
      #   { username: /#{::Regexp.escape(@q)}/i }
      # ).pluck(:id))

      # @organisations = Organisation.and(name: /#{::Regexp.escape(@q)}/i)
      # @gatherings = Gathering.and(name: /#{::Regexp.escape(@q)}/i).and(listed: true).and(:privacy.ne => 'secret')
      # @places = Place.and(name: /#{::Regexp.escape(@q)}/i)

      results += @events.limit(5).map { |event| { label: %(<i class="fa fa-fw fa-calendar"></i> #{event.name} (#{concise_when_details(event)})), value: %(event:"#{event.name}") } }
      # results += @accounts.limit(5).map { |account| { label: %(<i class="fa fa-fw fa-user"></i> #{account.name}), value: %(account:"#{account.name}") } }
      # results += @organisations.limit(5).map { |organisation| { label: %(<i class="fa fa-fw fa-flag"></i> #{organisation.name}), value: %(organisation:"#{organisation.name}") } }
      # results += @gatherings.limit(5).map { |gathering| { label: %(<i class="fa fa-fw fa-moon"></i> #{gathering.name}), value: %(gathering:"#{gathering.name}") } }
      # results += @places.limit(5).map { |place| { label: %(<i class="fa fa-fw fa-map"></i> #{place.name}), value: %(place:"#{place.name}") } }

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
        when 'gatherings'
          @gatherings = Gathering.and(name: /#{Regexp.escape(@q)}/i).and(listed: true).and(:privacy.ne => 'secret')
          @gatherings = @gatherings.paginate(page: params[:page], per_page: 10).order('name asc')
        when 'places'
          @places = Place.and(name: /#{Regexp.escape(@q)}/i)
          @places = @places.paginate(page: params[:page], per_page: 10).order('name asc')
        when 'organisations'
          @organisations = Organisation.and(name: /#{Regexp.escape(@q)}/i)
          @organisations = @organisations.paginate(page: params[:page], per_page: 10).order('name asc')
        when 'events'
          @events = Event.live.public.legit.future(1.month.ago).and(:id.in => Event.all.or(
            { name: /#{Regexp.escape(@q)}/i },
            { description: /#{Regexp.escape(@q)}/i }
          ).pluck(:id))
          @events = @events.paginate(page: params[:page], per_page: 10).order('start_time asc')
        when 'accounts'
          @accounts = Account.public
          @accounts = @accounts.and(:id.in => Account.all.or(
            { name: /#{Regexp.escape(@q)}/i },
            { name_transliterated: /#{Regexp.escape(@q)}/i },
            { email: /#{Regexp.escape(@q)}/i },
            { username: /#{Regexp.escape(@q)}/i }
          ).pluck(:id))
          @accounts = @accounts.paginate(page: params[:page], per_page: 10).order('last_active desc')
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
