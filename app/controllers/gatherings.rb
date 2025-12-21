Dandelion::App.controller do
  get '/gatherings', provides: %i[html json] do
    @gatherings = if current_account && params[:my_gatherings]
                    Gathering.and(:id.in => current_account.memberships.pluck(:gathering_id))
                  else
                    Gathering.and(:listed => true, :privacy.ne => 'secret')
                  end
    @gatherings = params[:order] == 'membership_count' ? @gatherings.order('membership_count desc') : @gatherings.order('created_at desc')
    @gatherings = @gatherings.and(:id.in => Gathering.search(params[:q], @gatherings).pluck(:id)) if params[:q]

    case content_type
    when :html
      @gatherings = @gatherings.and(has_image: true)
      @gatherings = @gatherings.paginate(page: params[:gatherings_page], per_page: 50)
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
      results: @gatherings.map { |gathering| { id: gathering.id.to_s, text: "#{gathering.name} (id:#{gathering.id})" } }
    }.to_json
  end

  get '/g/new' do
    sign_in_required!
    @gathering = Gathering.new(currency: current_account.default_currency)
    @gathering.welcome_email = @gathering.welcome_email_default
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
      @edit_slug = params[:slug] # Use original slug for form action, not the (possibly invalid) in-memory value
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
    @membership.set(unsubscribed: false)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  get '/g/:slug/unsubscribe' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership.set(unsubscribed: true)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  get '/g/:slug/show_in_sidebar' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership.set(hide_from_sidebar: false)
    redirect "/g/#{@gathering.slug}"
  end

  get '/g/:slug/hide_from_sidebar' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership.set(hide_from_sidebar: true)
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

    destination = current_account.memberships.find_by(admin: true, gathering_id: params[:gathering_id]).gathering
    @gathering.copy_structure_to(destination, account: destination.account)

    redirect "/g/#{destination.slug}"
  end
end
