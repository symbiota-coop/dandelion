Dandelion::App.controller do
  get '/gatherings', provides: %i[html json] do
    case content_type
    when :html
      @gatherings = if current_account && params[:my_gatherings]
                      Gathering.and(:id.in => current_account.memberships.pluck(:gathering_id))
                    else
                      Gathering.and(listed: true).and(:privacy.ne => 'secret')
                    end
      @gatherings = params[:order] == 'created_at' ? @gatherings.order('created_at desc') : @gatherings.order('membership_count desc')
      if params[:q]
        @gatherings = @gatherings.and(:id.in => Gathering.all.or(
          { name: /#{Regexp.escape(params[:q])}/i },
          { intro_for_non_members: /#{Regexp.escape(params[:q])}/i }
        ).pluck(:id))
      end
      @gatherings = @gatherings.paginate(page: params[:gatherings_page], per_page: 50)
      if request.xhr?
        if params[:display] == 'map'
          @lat = params[:lat]
          @lng = params[:lng]
          @zoom = params[:zoom]
          @south = params[:south]
          @west = params[:west]
          @north = params[:north]
          @east = params[:east]
          box = [[@west.to_f, @south.to_f], [@east.to_f, @north.to_f]]

          @gatherings = @gatherings.and(coordinates: { '$geoWithin' => { '$box' => box } }) unless @gatherings.empty?
          @points_count = @gatherings.count
          @points = @gatherings.to_a
          partial :'maps/map', locals: { stem: '/gatherings', dynamic: true, points: @points, points_count: @points_count, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom }
        end
      else
        erb :'gatherings/gatherings'
      end
    when :json
      sign_in_required!
      @gatherings = Gathering.and(:id.in => current_account.memberships.pluck(:gathering_id))
      @gatherings = @gatherings.and(name: /#{Regexp.escape(params[:q])}/i) if params[:q]
      @gatherings = @gatherings.and(id: params[:id]) if params[:id]
      {
        results: @gatherings.map { |gathering| { id: gathering.id.to_s, text: "#{gathering.name} (id:#{gathering.id})" } }
      }.to_json
    end
  end

  get '/g/new' do
    sign_in_required!
    @gathering = Gathering.new(currency: current_account.default_currency)
    @gathering.welcome_email = %(<p>Hi %recipient.firstname%,</p>

<p>You're now a member of %gathering.name% on Dandelion.</p>

<p>
  %sign_in_details%
</p>)
    Gathering.enablable.each do |x|
      @gathering.send("enable_#{x}=", true)
    end
    @gathering.listed = true
    @gathering.enable_partial_payments = true
    @gathering.enable_comments_on_gathering_homepage = false
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

  get '/g/:slug' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    if @membership
      if request.xhr?
        partial :newsfeed, locals: { notifications: @gathering.notifications_as_circle.order('created_at desc').page(params[:page]), include_circle_name: false }
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
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!
    partial :'gatherings/todos'
  end

  get '/g/:slug/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    erb :'gatherings/build'
  end

  post '/g/:slug/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    if @gathering.update_attributes(mass_assigning(params[:gathering], Gathering))
      flash[:notice] = 'The gathering was saved.'
      redirect "/g/#{@gathering.slug}"
    else
      flash.now[:error] = 'Some errors prevented the gathering from being created'
      erb :'gatherings/build'
    end
  end

  get '/g/:slug/destroy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @gathering.destroy
    flash[:notice] = 'The gathering was deleted'
    redirect '/'
  end

  get '/g/:slug/subscribe' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    partial :'gatherings/subscribe', locals: { membership: @membership }
  end

  get '/g/:slug/set_subscribe' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership.update_attribute(:unsubscribed, nil)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  get '/g/:slug/unsubscribe' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership.update_attribute(:unsubscribed, true)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  get '/g/:slug/show_in_sidebar' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership.update_attribute(:hide_from_sidebar, nil)
    redirect "/g/#{@gathering.slug}"
  end

  get '/g/:slug/hide_from_sidebar' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership.update_attribute(:hide_from_sidebar, true)
    redirect "/g/#{@gathering.slug}"
  end

  get '/g/:slug/map' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @accounts = @gathering.members
    erb :'gatherings/map'
  end
end
