Dandelion::App.controller do
  get '/search' do
    if request.xhr?
      @q = params[:term]
      @type = params[:type]
      halt if @q.nil? || @q.length < 3 || @q.length > 200

      results = []

      if !@type || @type == 'events'
        results += Event.search(@q, Event.live.public.browsable.future(1.month.ago), limit: 5, build_records: true, phrase_boost: 1.5, include_text_search: true).map do |event|
          { label: %(<i class="bi bi-calendar-event"></i> #{event.name} (#{concise_when_details(event)})), value: %(event:"#{event.name}") }
        end
      end

      if !@type || @type == 'accounts'
        results += Account.search(@q, Account.public, limit: 5, build_records: true, phrase_boost: 1.5, include_text_search: true).map do |account|
          { label: %(<i class="bi bi-person-fill"></i> #{account.name}), value: %(account:"#{account.name}") }
        end
      end

      if !@type || @type == 'organisations'
        results += Organisation.search(@q, Organisation.all, limit: 5, build_records: true, phrase_boost: 1.5, include_text_search: true).map do |organisation|
          { label: %(<i class="bi bi-flag-fill"></i> #{organisation.name}), value: %(organisation:"#{organisation.name}") }
        end
      end

      if !@type || @type == 'gatherings'
        results += Gathering.search(@q, Gathering.and(listed: true).and(:privacy.ne => 'secret'), limit: 5, build_records: true, phrase_boost: 1.5, include_text_search: true).map do |gathering|
          { label: %(<i class="bi bi-moon-fill"></i> #{gathering.name}), value: %(gathering:"#{gathering.name}") }
        end
      end

      results.to_json
    else
      @q = params[:q]
      @type = params[:type] || 'events'

      if @q
        %w[gathering organisation event account].each do |t|
          next unless params[:q].starts_with?("#{t}:")

          @q += '"' unless @q.ends_with?('"')
          @q = @q.match(/#{t}\s*:"(.+)"/)[1]
          @type = t.pluralize
        end
        case @type
        when 'events'
          if params[:q] && params[:q].starts_with?('event:')
            @events = Event.live.public.browsable.future(1.month.ago).and(name: @q)
            redirect "/e/#{@events.first.slug}" if @events.count == 1
          end
          @events = Event.search(@q, Event.live.public.browsable.future(1.month.ago), build_records: true, phrase_boost: 1.5, include_text_search: true)
          @events = @events.paginate(page: params[:page], per_page: 20)
        when 'accounts'
          if params[:q] && params[:q].starts_with?('account:')
            @accounts = Account.public.and(name: @q)
            if @accounts.count == 1
              if params[:message]
                redirect "/messages/#{@accounts.first.id}"
              else
                redirect "/u/#{@accounts.first.username}"
              end
            end
          end
          @accounts = Account.search(@q, Account.public, build_records: true, phrase_boost: 1.5, include_text_search: true)
          @accounts = @accounts.paginate(page: params[:page], per_page: 20)
        when 'organisations'
          if params[:q] && params[:q].starts_with?('organisation:')
            @organisations = Organisation.and(name: @q)
            redirect "/o/#{@organisations.first.slug}" if @organisations.count == 1
          end
          @organisations = Organisation.search(@q, Organisation.all, build_records: true, phrase_boost: 1.5, include_text_search: true)
          @organisations = @organisations.paginate(page: params[:page], per_page: 20)
        when 'gatherings'
          if params[:q] && params[:q].starts_with?('gathering:')
            @gatherings = Gathering.all.and(listed: true).and(:privacy.ne => 'secret').and(name: @q)
            redirect "/g/#{@gatherings.first.slug}" if @gatherings.count == 1
          end
          @gatherings = Gathering.search(@q, Gathering.and(listed: true).and(:privacy.ne => 'secret'), build_records: true, phrase_boost: 1.5, include_text_search: true)
          @gatherings = @gatherings.paginate(page: params[:page], per_page: 20)
        end
      end

      erb :search
    end
  end
end
