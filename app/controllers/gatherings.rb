Dandelion::App.controller do
  get '/gatherings', provides: %i[html json] do
    @gatherings = if current_account && params[:my_gatherings]
                    Gathering.and(:id.in => current_account.memberships.pluck(:gathering_id))
                  elsif admin?
                    # Site admins see every gathering, unlisted and secret ones too
                    Gathering.all
                  else
                    Gathering.and(:listed => true, :privacy.ne => 'secret')
                  end
    @gatherings = params[:order] == 'membership_count' ? @gatherings.order('membership_count desc') : @gatherings.order('created_at desc')
    @gatherings = @gatherings.and(:id.in => Gathering.search(params[:q], @gatherings).pluck(:id)) if params[:q]

    case content_type
    when :html
      # Your own gatherings, and every gathering for site admins, show whether or not they have an image
      @gatherings = @gatherings.and(has_image: true) unless (current_account && params[:my_gatherings]) || admin?
      @gatherings = @gatherings.paginate(page: params[:gatherings_page], per_page: 16)
      erb :'gatherings/gatherings'
    when :json
      map_json(@gatherings)
    end
  end

  get '/gatherings/autocomplete', provides: :json do
    sign_in_required!
    @gatherings = Gathering.and(:id.in => current_account.memberships.pluck(:gathering_id))
    @gatherings = @gatherings.and(:id.in => Gathering.search(params[:q], @gatherings).pluck(:id)) if params[:q]
    @gatherings = @gatherings.and(id: params[:id]) if params[:id]
    {
      results: @gatherings.only(:name).map { |gathering| { id: gathering.id.to_s, text: "#{gathering.name} (id:#{gathering.id})" } }
    }.to_json
  end

  get '/g/new' do
    sign_in_required!
    @gathering = Gathering.new(currency: preferred_currency)
    @gathering.welcome_email = @gathering.welcome_email_default
    Gathering.enablable.each do |x|
      @gathering.send("enable_#{x}=", true) unless x == 'shift_worth'
    end
    @gathering.enable_partial_payments = true
    erb :'gatherings/build'
  end

  post '/g/new' do
    sign_in_required!
    @gathering = Gathering.new(mass_assigning(params[:gathering], Gathering))
    @gathering.account = current_account
    if @gathering.save
      redirect "/g/#{@gathering.slug}"
    else
      flash.now[:error] = 'Some errors prevented the gathering from being created'
      erb :'gatherings/build'
    end
  end

  get '/g/:slug', prerender: true do # rubocop:disable Dandelion/GatheringPermission -- it checks itself: members and admins see the page, and anyone else is sent to join or apply
    @gathering = gathering_from_params || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    if @membership || gathering_admin?
      if request.xhr?
        partial :newsfeed, locals: { notifications: @gathering.notifications_as_circle.order('created_at desc').paginate(page: params[:page]), include_circle_name: false }
      elsif @gathering.redirect_home
        redirect @gathering.redirect_home
      else
        erb :'gatherings/gathering'
      end
    else
      case @gathering.privacy
      when 'open'
        redirect "/g/#{@gathering.slug}/join"
      when 'closed'
        redirect "/g/#{@gathering.slug}/apply"
      when 'secret'
        redirect '/'
      end
    end
  end

  get '/g/:slug/todos' do
    @gathering = gathering_from_params || not_found
    membership_required!
    partial :'gatherings/todos'
  end

  get '/g/:slug/edit' do
    @gathering = gathering_from_params || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    erb :'gatherings/build'
  end

  post '/g/:slug/edit' do
    @gathering = gathering_from_params || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    if @gathering.update_attributes(mass_assigning(params[:gathering], Gathering))
      flash[:notice] = 'The gathering was saved.'
      redirect "/g/#{@gathering.slug}"
    else
      @edit_slug = params[:slug] # Use original slug for form action, not the (possibly invalid) in-memory value
      flash.now[:error] = 'Some errors prevented the gathering from being created'
      erb :'gatherings/build'
    end
  end

  post '/g/:slug/destroy' do
    @gathering = gathering_from_params || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @gathering.destroy
    flash[:notice] = 'The gathering was deleted'
    redirect '/'
  end

  get '/g/:slug/subscribe' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!(site_admins: false)
    partial :'gatherings/subscribe', locals: { membership: @membership }
  end

  post '/g/:slug/set_subscribe' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @membership.set(unsubscribed: false)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  get '/g/:slug/unsubscribe' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!(site_admins: false)
    @membership.set(unsubscribed: true)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  post '/g/:slug/show_in_sidebar' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @membership.set(hide_from_sidebar: false)
    redirect "/g/#{@gathering.slug}"
  end

  post '/g/:slug/hide_from_sidebar' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @membership.set(hide_from_sidebar: true)
    redirect "/g/#{@gathering.slug}"
  end

  get '/g/:slug/copy' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @destination_memberships = current_account.memberships.and(admin: true).and(:gathering_id.ne => @gathering.id)
    if @destination_memberships.empty?
      flash[:error] = 'You need to be an admin of another gathering to copy into it.'
      redirect "/g/#{@gathering.slug}"
    end

    erb :'gatherings/copy'
  end

  post '/g/:slug/copy' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!

    destination_membership = current_account.memberships.and(admin: true).and(:gathering_id.ne => @gathering.id).find_by(gathering_id: params[:gathering_id])
    unless destination_membership
      flash[:error] = "Please choose a gathering you're an admin of."
      redirect "/g/#{@gathering.slug}/copy"
    end

    destination = destination_membership.gathering
    @gathering.copy_structure_to(destination, account: destination.account)

    redirect "/g/#{destination.slug}"
  end
end
