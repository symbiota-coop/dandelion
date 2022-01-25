Dandelion::App.controller do
  get '/g/:slug/members', provides: %i[html csv] do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @memberships = @gathering.memberships
    @gathering.radio_scopes.select { |k, v, _t, _r| params[k] == v.to_s && params[k] != 'all' }.each do |_k, _v, _t, r|
      @memberships = @memberships.and(:id.in => r.pluck(:id))
    end
    @gathering.check_box_scopes.select { |k, _t, _r| params[k] }.each do |_k, _t, r|
      @memberships = @memberships.and(:id.in => r.pluck(:id))
    end
    @memberships = @memberships.and(:account_id.in => Account.and(name: /#{::Regexp.escape(params[:q])}/i).pluck(:id)) if params[:q]
    @memberships = @memberships.order('created_at desc')
    case content_type
    when :html
      erb :'gatherings/members'
    when :csv
      CSV.generate do |csv|
        csv << %w[name email proposed_by accepted_at answers options requested_contribution paid]
        @memberships.each do |membership|
          csv << [
            membership.account.name,
            membership.account.email,
            (membership.proposed_by.map(&:name).to_sentence(last_word_connector: ' and ') if membership.proposed_by),
            membership.created_at.to_s(:db),
            (membership.mapplication.answers if membership.mapplication && membership.mapplication.answers),
            membership.optionships.map { |optionship| [optionship.option.name, optionship.option.cost_per_person] },
            membership.requested_contribution,
            membership.paid
          ]
        end
      end
    end
  end

  get '/g/:slug/join' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    redirect "/g/#{@gathering.slug}/apply" unless @gathering.privacy == 'open'
    @title = @gathering.name
    @og_desc = "#{@gathering.name} is being co-created on Dandelion"
    @og_image = @gathering.image.url if @gathering.image
    @account = Account.new
    erb :'gatherings/join'
  end

  post '/g/:slug/join' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    halt unless @gathering.privacy == 'open'

    if current_account
      @account = current_account
    else
      redirect back unless params[:account] && params[:account][:email]
      if (@account = Account.find_by(email: params[:account][:email].downcase))
        kick! notice: 'Sign in to continue'
      else
        @account = Account.new(mass_assigning(params[:account], Account))
        @account.password = Account.generate_password # not used
        if @account.save
          @account.sign_ins.create(env: env_yaml)
          session[:account_id] = @account.id.to_s
        else
          flash[:error] = '<strong>Oops.</strong> Some errors prevented the account from being saved.'
          redirect back
        end
      end
    end

    if @gathering.memberships.find_by(account: @account)
      flash[:notice] = "You're already part of that gathering"
      redirect back
    else
      @gathering.memberships.create! account: @account
      redirect "/g/#{@gathering.slug}"
    end
  end

  get '/g/:slug/leave' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!
    flash[:notice] = "You left #{@gathering.name}"
    @membership.destroy
    redirect '/'
  end

  post '/g/:slug/add_member' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!

    if !@membership.admin? && @membership.invitations_remaining <= 0
      flash[:error] = 'You have run out of invitations'
      redirect back
    end

    unless params[:email]
      flash[:error] = 'Please provide an email address'
      redirect back
    end

    unless (@account = Account.find_by(email: params[:email].downcase))
      @account = Account.new(name: params[:email].split('@').first, email: params[:email], password: Account.generate_password)
      unless @account.save
        flash[:error] = '<strong>Oops.</strong> Some errors prevented the account from being saved.'
        redirect back
      end
    end

    if @gathering.memberships.find_by(account: @account)
      flash[:notice] = 'That person is already a member of the gathering'
      redirect back
    else
      @gathering.memberships.create! account: @account, prevent_notifications: params[:prevent_notifications], added_by: current_account
      redirect back
    end
  end

  get '/memberships/:id/make_admin' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.admin = true
    membership.admin_status_changed_by = current_account
    membership.save!
    membership.notifications.and(:type.in => %w[made_admin unadmined]).destroy_all
    membership.notifications.create! circle: @gathering, type: 'made_admin'
    redirect back
  end

  get '/memberships/:id/unadmin' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.admin = false
    membership.admin_status_changed_by = current_account
    membership.save!
    membership.notifications.and(:type.in => %w[made_admin unadmined]).destroy_all
    membership.notifications.create! circle: @gathering, type: 'unadmined'
    redirect back
  end

  get '/memberships/:id/remove' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.destroy
    redirect back
  end

  post '/memberships/:id/paid' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.paid = params[:paid]
    membership.save
    200
  end

  post '/memberships/:id/invitations_granted' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.invitations_granted = params[:invitations_granted]
    membership.save
    200
  end

  post '/memberships/:id/member_of_facebook_group' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.update_attribute(:member_of_facebook_group, params[:member_of_facebook_group])
    200
  end

  get '/membership_row/:id' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    partial :'gatherings/membership_row', locals: { membership: membership }
  end
end
