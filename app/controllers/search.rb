Dandelion::App.controller do
  get '/search' do
    if request.xhr?
      @q = params[:term]
      @type = params[:type]
      halt if @q.nil? || @q.length < 3

      results = []

      if !@type || @type == 'events'
        results += search(Event, Event.live.public.legit.future(1.month.ago), @q, 5).map do |event|
          { label: %(<i class="bi bi-calendar-event"></i> #{event.name} (#{concise_when_details(event)})), value: %(event:"#{event.name}") }
        end
      end

      if !@type || @type == 'accounts'
        results += search(Account, Account.public, @q, 5).map do |account|
          { label: %(<i class="bi bi-person-fill"></i> #{account.name}), value: %(account:"#{account.name}") }
        end
      end

      if !@type || @type == 'organisations'
        results += search(Organisation, Organisation.all, @q, 5).map do |organisation|
          { label: %(<i class="bi bi-flag-fill"></i> #{organisation.name}), value: %(organisation:"#{organisation.name}") }
        end
      end

      if !@type || @type == 'gatherings'
        results += search(Gathering, Gathering.and(listed: true).and(:privacy.ne => 'secret'), @q, 5).map do |gathering|
          { label: %(<i class="bi bi-moon-fill"></i> #{gathering.name}), value: %(gathering:"#{gathering.name}") }
        end
      end

      results.to_json
    else
      @type = params[:type] || 'events'
      if (@q = params[:q])
        %w[gathering organisation event account].each do |t|
          next unless params[:q].starts_with?("#{t}:")

          @q += '"' unless @q.ends_with?('"')
          @q = @q.match(/#{t}\s*:"(.+)"/)[1]
          @type = t.pluralize
        end
        case @type
        when 'events'
          if params[:q] && params[:q].starts_with?('event:')
            @events = Event.live.public.legit.future(1.month.ago).and(name: @q)
            redirect "/e/#{@events.first.slug}" if @events.count == 1
          end
          @events = search(Event, Event.live.public.legit.future(1.month.ago), @q, 25)
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
        end
      end

      erb :search
    end
  end
end
