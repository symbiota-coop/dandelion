Dandelion::App.controller do
  get '/search' do
    if request.xhr?
      @q = params[:term]
      halt if @q.nil? || @q.length < 3

      results = []

      match_selector = Event.live.public.legit.future(1.month.ago).selector
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
      }, {
        '$match': match_selector
      }]
      aggregate = Event.collection.aggregate(pipeline)
      results += aggregate.first(5).map do |event_hash|
        event = Event.new(event_hash.select { |k, _v| Event.fields.keys.include?(k.to_s) })
        { label: %(<i class="fa fa-fw fa-calendar"></i> #{event.name} (#{concise_when_details(event)})), value: %(event:"#{event.name}") }
      end

      match_selector = Account.public.selector
      pipeline = [{
        '$search': {
          index: 'accounts',
          text: {
            query: @q,
            path: {
              wildcard: '*'
            }
          }
        }
      }, {
        '$match': match_selector
      }]
      aggregate = Account.collection.aggregate(pipeline)
      results += aggregate.first(5).map do |account_hash|
        account = Account.new(account_hash.select { |k, _v| Account.fields.keys.include?(k.to_s) })
        { label: %(<i class="fa fa-fw fa-user"></i> #{account.name}), value: %(account:"#{account.name}") }
      end

      match_selector = Organisation.all.selector
      pipeline = [{
        '$search': {
          index: 'organisations',
          text: {
            query: @q,
            path: {
              wildcard: '*'
            }
          }
        }
      }, {
        '$match': match_selector
      }]
      aggregate = Organisation.collection.aggregate(pipeline)
      results += aggregate.first(5).map do |organisation_hash|
        organisation = Organisation.new(organisation_hash.select { |k, _v| Organisation.fields.keys.include?(k.to_s) })
        { label: %(<i class="fa fa-fw fa-flag"></i> #{organisation.name}), value: %(organisation:"#{organisation.name}") }
      end

      match_selector = Gathering.and(listed: true).and(:privacy.ne => 'secret').selector
      pipeline = [{
        '$search': {
          index: 'gatherings',
          text: {
            query: @q,
            path: {
              wildcard: '*'
            }
          }
        }
      }, {
        '$match': match_selector
      }]
      aggregate = Gathering.collection.aggregate(pipeline)
      results += aggregate.first(5).map do |gathering_hash|
        gathering = Gathering.new(gathering_hash.select { |k, _v| Gathering.fields.keys.include?(k.to_s) })
        { label: %(<i class="fa fa-fw fa-moon"></i> #{gathering.name}), value: %(gathering:"#{gathering.name}") }
      end

      match_selector = Place.all.selector
      pipeline = [{
        '$search': {
          index: 'places',
          text: {
            query: @q,
            path: {
              wildcard: '*'
            }
          }
        }
      }, {
        '$match': match_selector
      }]
      aggregate = Place.collection.aggregate(pipeline)
      results += aggregate.first(5).map do |place_hash|
        place = Place.new(place_hash.select { |k, _v| Place.fields.keys.include?(k.to_s) })
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
