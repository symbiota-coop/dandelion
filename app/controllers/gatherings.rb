Dandelion::App.controller do
  get '/gatherings', provides: %i[html json] do
    case content_type
    when :html
      @gatherings = if current_account && params[:my_gatherings]
                      Gathering.and(:id.in => current_account.memberships.pluck(:gathering_id))
                    else
                      Gathering.and(:listed => true, :privacy.ne => 'secret', :image_uid.ne => nil)
                    end
      @gatherings = params[:order] == 'membership_count' ? @gatherings.order('membership_count desc') : @gatherings.order('created_at desc')
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
          partial :'maps/map', locals: { stem: '/gatherings', dynamic: true, points: @points, points_count: @points_count, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom, fill_screen: true }
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
      @gathering.send("enable_#{x}=", true) unless x == 'shift_worth'
    end
    @gathering.listed = true
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

  get '/g/:slug/birthdays', provides: :ics do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!
    cal = Icalendar::Calendar.new
    cal.append_custom_property('X-WR-CALNAME', "#{@gathering.name} birthdays")
    @memberships = @gathering.members.each do |account|
      next unless account.date_of_birth

      cal.event do |e|
        e.summary = "#{account.name}'s #{(account.age + 1).ordinalize} birthday"
        e.dtstart = Icalendar::Values::Date.new(account.next_birthday.to_date)
        e.description = %(#{ENV['BASE_URI']}/u/#{account.username})
        e.uid = account.id.to_s
      end
    end
    cal.to_ical
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

  get '/g/:slug/copy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    erb :'gatherings/copy'
  end

  post '/g/:slug/copy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!

    g1 = @gathering
    g2 = current_account.memberships.find_by(admin: true, gathering_id: params[:gathering_id]).gathering

    g1.timetables.each do |timetable1|
      timetable2 = g2.timetables.create! name: timetable1.name, account: g2.account
      timetable1.tslots.each do |tslot|
        timetable2.tslots.create! name: tslot.name, o: tslot.o
      end
      timetable1.spaces.each do |space|
        timetable2.spaces.create! name: space.name, o: space.o
      end
    end

    g1.rotas.each do |rota1|
      rota2 = g2.rotas.create! name: rota1.name, account: g2.account
      rota1.rslots.each do |rslot|
        rota2.rslots.create! name: rslot.name, o: rslot.o, worth: rslot.worth
      end
      rota1.roles.each do |role|
        rota2.roles.create! name: role.name, o: role.o, worth: role.worth
      end
    end

    g1.options.each do |option|
      g2.options.create! account: option.account, name: option.name, description: option.description, capacity: option.capacity, cost: option.cost, split_cost: option.split_cost, type: option.type, by_invitation: option.by_invitation, hide_members: option.hide_members
    end

    redirect "/g/#{g2.slug}"
  end
end
