Dandelion::App.controller do
  get '/g/:slug/members', provides: %i[html csv] do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @memberships = @gathering.memberships
    @member_filters = @gathering.member_filters
    chosen = @member_filters[:selects].filter_map { |param, _label, options| options.find { |value, _l, _r| value.to_s == params[param] } }
    chosen += @member_filters[:checkboxes].select { |param, _label, _r| params[param] }
    chosen.each do |_value, _label, r|
      @memberships = @memberships.and(:id.in => r.pluck(:id))
    end
    @memberships = @memberships.and(:account_id.in => Account.search(params[:q], child_scope: @memberships, regex_search: true).pluck(:id)) if params[:q]
    @memberships = @memberships.includes(:account, teamships: :team, optionships: :option).order('created_at desc')
    case content_type
    when :html
      erb :'gatherings/members'
    when :csv
      # By design, any confirmed member (not just admins) can export the full member list including emails
      CSV.generate do |csv|
        row = %w[name firstname lastname email proposed_by accepted_at options requested_contribution paid]
        @gathering.joining_questions_a.each { |q| row << q }
        @gathering.application_questions_a.each { |q| row << q }
        csv << row
        # A query per collection rather than a few per member, though it also fetches tickets and shifts the CSV doesn't use
        Membership.preload_rows(@gathering, @memberships, viewer: nil).each do |membership|
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
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    redirect "/g/#{@gathering.slug}/apply" unless @gathering.privacy == 'open'
    @title = @gathering.name
    @og_desc = "#{@gathering.name} is being co-created on Dandelion"
    @og_image = @gathering.image.encode('jpg', '-quality 90').thumb('1200x630').url if @gathering.image
    @account = Account.new
    erb :'gatherings/join'
  end

  post '/g/:slug/join' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    halt unless @gathering.privacy == 'open'

    if current_account
      @account = current_account
    else

      validate_recaptcha

      redirect back unless params[:account] && params[:account][:email]
      if (@account = Account.find_by(email: params[:account][:email].downcase.strip))
        kick! notice: 'Sign in to continue'
      else
        @account = Account.new(mass_assigning(params[:account], Account))
        @account.password = Account.generate_password # not used
        if @account.save
          @account.sign_ins.create(request: request)
          start_session!(@account)
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

  post '/g/:slug/leave' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!
    flash[:notice] = "You left #{@gathering.name}"
    @membership.destroy
    redirect '/'
  end

  post '/g/:slug/add_member' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required! unless gathering_admin?

    if !gathering_admin? && @membership.invitations_remaining <= 0
      flash[:error] = 'You have run out of invitations'
      redirect back
    end

    unless params[:email]
      flash[:error] = 'Please provide an email address'
      redirect back
    end

    unless (@account = Account.find_by(email: params[:email].downcase.strip))
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

  post '/g/:slug/memberships/:id/make_admin' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    membership = @gathering.memberships.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.admin = true
    membership.admin_status_changed_by = current_account
    membership.save!
    membership.notifications.and(:type.in => %w[made_admin unadmined]).destroy_all
    membership.notifications.create! circle: @gathering, type: 'made_admin'
    redirect back
  end

  post '/g/:slug/memberships/:id/unadmin' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    membership = @gathering.memberships.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.admin = false
    membership.admin_status_changed_by = current_account
    membership.save!
    membership.notifications.and(:type.in => %w[made_admin unadmined]).destroy_all
    membership.notifications.create! circle: @gathering, type: 'unadmined'
    redirect back
  end

  post '/g/:slug/memberships/:id/remove' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    membership = @gathering.memberships.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.destroy
    redirect back
  end

  post '/g/:slug/memberships/:id/paid' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    membership = @gathering.memberships.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.paid = params[:paid]
    membership.save
    200
  end

  post '/g/:slug/memberships/:id/invitations_granted' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    membership = @gathering.memberships.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.invitations_granted = params[:invitations_granted]
    membership.save
    200
  end

  post '/g/:slug/memberships/:id/shift_points_required' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    membership = @gathering.memberships.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    membership.shift_points_required = params[:shift_points_required]
    membership.save
    200
  end

  get '/g/:slug/membership_row/:id' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    membership = @gathering.memberships.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    partial :'gatherings/membership_row', locals: { membership: membership }
  end

  get '/g/:slug/memberships/:id' do
    @gathering = Gathering.find_by_slug_or_id(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership = @gathering.memberships.find(params[:id]) || not_found
    # It opens in a modal on the members page; visited directly, it goes to that page
    request.xhr? ? partial(:'gatherings/membership_modal', locals: { membership: @membership }) : redirect("/g/#{@gathering.slug}/members")
  end
end
