Dandelion::App.controller do
  get '/private_sessions', provides: %i[html json], access: :public do
    # My private sessions (_scope_toggle.erb): the account's own, secret ones too
    @private_sessions = current_account && params[:my_private_sessions] ? current_account.private_sessions : PrivateSession.listed
    @private_sessions = @private_sessions.order('created_at desc')
    # ?q[x]=1 or ?tag[]=x give a hash or an array, which isn't a filter, so the list shows unfiltered rather than a 500
    if params[:q].is_a?(String)
      q = /#{Regexp.escape(params[:q])}/i
      @private_sessions = @private_sessions.and('$or' => [{ title: q }, { description: q }, { tag_names_cache: q }])
    end
    if params[:tag].is_a?(String)
      tag = PrivateSessionTag.find_by(name: params[:tag].downcase)
      @private_sessions = @private_sessions.and(:id.in => tag ? tag.private_session_tagships.pluck(:private_session_id) : [])
    end
    # Online or In person, as events search has them: either or, and a session offered both ways under each. Near a
    # place ticks In person (near_place_ticks_in_person)
    near_place_ticks_in_person
    if params[:online]
      @private_sessions = @private_sessions.and(:delivery.in => %w[online either])
    elsif params[:in_person]
      @private_sessions = @private_sessions.and(:delivery.in => %w[in_person either])
    end
    @private_sessions = @private_sessions.and(coordinates: { '$geoWithin' => { '$box' => @bounding_box } }) if set_bounding_box
    case content_type
    when :html
      @private_sessions = @private_sessions.includes(:account).paginate(page: params[:page], per_page: 20)
      @title = 'Private sessions'
      erb :'private_sessions/private_sessions'
    when :json
      # The map view's points in its box (maps/_map.erb), with the list's filters
      map_json(@private_sessions)
    end
  end

  get '/private_sessions/new', access: :signed_in do
    @private_session = current_account.private_sessions.new(max_participants: 1)
    @private_session.currency = @private_session.default_currency
    @title = 'Offer a private session'
    # From the list, in #modal (app.js, data-open-in-modal)
    request.xhr? ? partial(:modal_content, locals: { title: @title, form: :'private_sessions/form' }) : erb(:'private_sessions/build')
  end

  post '/private_sessions/new', access: :signed_in do
    @private_session = current_account.private_sessions.new(mass_assigning(params[:private_session], PrivateSession))
    saved = @private_session.save
    flash[:notice] = 'The private session was created.' if saved
    if request.xhr?
      # Created in #modal (data-save-in-modal, app.js): the session's page opens, or the form comes back with its errors
      return partial(:'private_sessions/modal') if saved

      return partial(:modal_content, locals: { title: 'Offer a private session', form: :'private_sessions/form' })
    end
    if saved
      redirect @private_session.path
    else
      flash.now[:error] = 'There was an error saving the private session'
      erb :'private_sessions/build'
    end
  end

  get '/ps/:slug', access: :public do
    @private_session = private_session_from_params
    @title = @private_session.title_with_name
    # From a list, it opens in #modal (app.js, data-open-in-modal)
    request.xhr? ? partial(:'private_sessions/modal') : erb(:'private_sessions/private_session')
  end

  get '/ps/:slug/edit' do
    @private_session = private_session_from_params
    own_private_session_only!
    @title = "Edit #{@private_session.title}"
    # From a session's modal, in #modal (app.js, data-open-in-modal)
    if request.xhr?
      partial :modal_content, locals: { title: 'Edit private session', form: :'private_sessions/form' }
    else
      erb :'private_sessions/build'
    end
  end

  post '/ps/:slug/edit' do
    @private_session = private_session_from_params
    own_private_session_only!
    saved = @private_session.update_attributes(mass_assigning(params[:private_session], PrivateSession))
    flash[:notice] = 'The private session was saved.' if saved
    if request.xhr?
      # Saved in #modal (data-save-in-modal, app.js): the session's page opens, or the form comes back with its errors
      return partial(:'private_sessions/modal') if saved

      return partial(:modal_content, locals: { title: 'Edit private session', form: :'private_sessions/form' })
    end
    if saved
      redirect @private_session.path
    else
      flash.now[:error] = 'There was an error saving the private session'
      erb :'private_sessions/build'
    end
  end

  # Vouch, signed out: sign in, and come back to the session's vouches (kick! keeps this URL to return to)
  get '/ps/:slug/vouch' do
    @private_session = private_session_from_params
    sign_in_required!(notice: 'Sign up or sign in to vouch for this session')
    redirect "#{@private_session.path}#vouches"
  end

  # Vouching for a session, with a testimonial or none, or changing the testimonial
  post '/ps/:slug/vouch' do
    @private_session = private_session_from_params
    sign_in_required!
    halt 403 if @private_session.account_id == current_account.id
    vouch = @private_session.private_session_vouches.find_or_initialize_by(account: current_account)
    created = vouch.new_record?
    vouch.testimonial = params[:testimonial]
    if vouch.save
      flash[:notice] = created ? 'Thanks for vouching.' : 'Your testimonial was saved.'
    else
      flash[:error] = "Your vouch couldn't be saved: #{vouch.errors.full_messages.to_sentence}"
    end
    redirect @private_session.path
  end

  post '/ps/:slug/unvouch' do
    @private_session = private_session_from_params
    sign_in_required!
    @private_session.private_session_vouches.find_by(account: current_account)&.destroy
    flash[:notice] = 'Your vouch was removed.'
    redirect @private_session.path
  end

  post '/ps/:slug/destroy' do
    @private_session = private_session_from_params
    own_private_session_only!
    @private_session.destroy
    flash[:notice] = 'The private session was deleted.'
    redirect "/u/#{@private_session.account.username}"
  end
end
