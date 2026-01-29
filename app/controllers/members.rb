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
    @memberships = @memberships.and(:account_id.in => Account.search(params[:q], child_scope: @memberships).pluck(:id)) if params[:q]
    @memberships = @memberships.includes(:account, teamships: :team, optionships: :option).order('created_at desc')
    case content_type
    when :html
      erb :'gatherings/members'
    when :csv
      CSV.generate do |csv|
        row = %w[name firstname lastname email proposed_by accepted_at options requested_contribution paid]
        @gathering.joining_questions_a.each { |q| row << q }
        @gathering.application_questions_a.each { |q| row << q }
        csv << row
        @memberships.each do |membership|
          row = [
            membership.account.name,
            membership.account.firstname,
            membership.account.lastname,
            membership.account.email,
            (membership.proposed_by.map(&:name).to_sentence(last_word_connector: ' and ') if membership.proposed_by),
            membership.created_at.to_fs(:db_local),
            membership.optionships.map { |optionship| [optionship.option.name, optionship.option.cost_per_person] },
            membership.requested_contribution,
            membership.paid
          ]
          @gathering.joining_questions_a.each { |q| row << membership.answers.to_h[q] } if membership.answers
          @gathering.application_questions_a.each { |q| row << membership.mapplication.answers.to_h[q] } if membership.mapplication && membership.mapplication.answers
          csv << row
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
    @og_image = @gathering.image.encode('jpg', '-quality 90').thumb('1200x630').url if @gathering.image
    @account = Account.new
    erb :'gatherings/join'
  end

  post '/g/:slug/join' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    halt unless @gathering.privacy == 'open'

    if current_account
      @account = current_account
    else

      validate_recaptcha

      redirect back unless params[:account] && params[:account][:email]
      if (@account = Account.find_by(email: params[:account][:email].downcase))
        kick! notice: 'Sign in to continue'
      else
        @account = Account.new(mass_assigning(params[:account], Account))
        @account.password = Account.generate_password # not used
        if @account.save
          @account.sign_ins.create(request: request)
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
      @gathering.memberships.create! account: @account, unsubscribed: true, answers: question_answer_pairs(params)
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
      flash[:warning] = 'That person is already a member of the gathering'
    else
      @gathering.memberships.create! account: @account, unsubscribed: true, prevent_notifications: params[:prevent_notifications], added_by: current_account
    end
    redirect back
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

  post '/memberships/:id/shift_points_required' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.shift_points_required = params[:shift_points_required]
    membership.save
    200
  end

  get '/membership_row/:id' do
    membership = Membership.find(params[:id]) || not_found
    @gathering = membership.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    partial :'gatherings/membership_row', locals: { membership: membership }
  end

  get '/g/:slug/memberships/:id' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership = @gathering.memberships.find(params[:id]) || not_found
    if request.xhr?
      partial :'gatherings/membership_modal', locals: { membership: @membership }
    else
      erb :'gatherings/membership'
    end
  end
end
