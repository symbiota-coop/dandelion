Dandelion::App.controller do
  get '/o/:slug/edit' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/build'
  end

  post '/o/:slug/edit' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    if @organisation.update_attributes(mass_assigning(params[:organisation], Organisation))
      flash[:notice] = 'The organisation was saved.'

      redirect(
        if @organisation.events.empty?
          "/events/new?organisation_id=#{@organisation.id}&new_org=1"
        elsif current_account.organisations.count == 1
          "/o/#{@organisation.slug}"
        else
          "/o/#{@organisation.slug}/edit"
        end
      )
    else
      @edit_slug = params[:slug] # Use original slug for form action, not the (possibly invalid) in-memory value
      flash.now[:error] = 'There was an error saving the organisation.'
      erb :'organisations/build'
    end
  end

  get '/o/:slug/delete' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/delete'
  end

  post '/o/:slug/destroy' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    if params[:organisation_name] && (params[:organisation_name] == @organisation.name)
      @organisation.destroy
      flash[:notice] = 'The organisation was deleted'
      redirect '/organisations'
    else
      flash[:error] = "The name you typed didn't match the organisation name"
      redirect back
    end
  end

  get '/o/:slug/emails' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/emails'
  end

  post '/o/:slug/emails' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    if @organisation.update_attributes(mass_assigning(params[:organisation], Organisation))
      flash[:notice] = 'Your settings were saved.'
      redirect "/o/#{@organisation.slug}/emails"
    else
      flash.now[:error] = 'There was an error saving your settings.'
      erb :'organisations/emails'
    end
  end

  get '/o/:slug/banned_emails' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/banned_emails'
  end

  post '/o/:slug/banned_emails' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    if @organisation.set(banned_emails: params[:organisation][:banned_emails])
      flash[:notice] = 'Your settings were saved.'
      redirect "/o/#{@organisation.slug}/banned_emails"
    else
      flash.now[:error] = 'There was an error saving your settings.'
      erb :'organisations/banned_emails'
    end
  end

  post '/o/:slug/add_follower' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!

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

    if @organisation.organisationships.find_by(account: @account)
      flash[:warning] = 'That person is already following the organisation'
    else
      @account.associate_with_organisation!(@organisation)
    end

    redirect back
  end

  post '/o/:slug/organisationships/admin' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find_by(account_id: params[:organisationship][:account_id]) || @organisation.organisationships.create(account_id: params[:organisationship][:account_id])
    @organisationship.set(admin: true) if @organisationship.persisted?
    redirect back
  end

  post '/o/:slug/organisationships/unadmin' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find_by(account_id: params[:account_id]) || not_found
    @organisationship.set(admin: false)
    redirect back
  end

  get '/o/:slug/tiers' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.new
    erb :'organisation_tiers/organisation_tiers'
  end

  post '/o/:slug/organisation_tiers/new' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.build(params[:organisation_tier])
    if @organisation_tier.save
      redirect "/o/#{@organisation.slug}/tiers"
    else
      flash.now[:error] = 'There was an error saving the tier.'
      erb :'organisation_tiers/organisation_tiers'
    end
  end

  get '/o/:slug/organisation_tiers/:organisation_tier_id/edit' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.find(params[:organisation_tier_id])
    erb :'organisation_tiers/build'
  end

  post '/o/:slug/organisation_tiers/:organisation_tier_id/edit' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.find(params[:organisation_tier_id])
    if @organisation_tier.update_attributes(mass_assigning(params[:organisation_tier], OrganisationTier))
      redirect "/o/#{@organisation.slug}/tiers"
    else
      flash.now[:error] = 'There was an error saving the tier.'
      erb :'organisation_tiers/build'
    end
  end

  get '/o/:slug/organisation_tiers/:organisation_tier_id/destroy' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.find(params[:organisation_tier_id])
    @organisation_tier.destroy
    redirect "/o/#{@organisation.slug}/tiers"
  end

  get '/o/:slug/followers', provides: %i[html csv] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationships = @organisation.organisationships.includes(:account).order('created_at desc')
    @organisationships = @organisationships.and(:account_id.in => Account.search(params[:q], @organisation.members).pluck(:id)) if params[:q]
    @organisationships = @organisationships.and(:monthly_donation_method.ne => nil) if params[:monthly_donor]
    @organisationships = @organisationships.and(monthly_donation_method: nil) if params[:not_a_monthly_donor]
    @organisationships = @organisationships.and(:stripe_connect_json.ne => nil) if params[:connected_to_stripe]
    if params[:subscribed_to_mailer]
      # Filter to org-subscribed, then exclude globally unsubscribed
      @organisationships = @organisationships.and(unsubscribed: false)
      excluded_ids = Account.and(organisation_ids_cache: @organisation.id, unsubscribed: true).pluck(:id)
      @organisationships = @organisationships.and(:account_id.nin => excluded_ids) if excluded_ids.any?
    end
    case content_type
    when :html
      erb :'organisations/followers'
    when :csv
      @organisation.send_followers_csv(current_account)
      flash[:notice] = 'You will receive the CSV via email shortly.'
      redirect back
    end
  end

  post '/o/:slug/followers' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation.import_from_csv(File.read(params[:csv]), :organisationships)
    flash[:notice] = 'The followers will be added shortly. Refresh the page to check progress.'
    redirect "/o/#{@organisation.slug}/followers"
  end

  get '/organisationships/:id/destroy' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only!
    @organisationship.destroy
    redirect back
  end

  get '/organisationships/:id/credit_balance' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only! unless current_account && current_account.id == @organisationship.account_id
    erb :'organisations/credit_balance'
  end

  post '/organisationships/:id/credit/:plus_or_minus' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only!
    @organisationship.creditings.create(account: current_account, amount: (params[:plus_or_minus] == 'plus' ? 1 : -1) * params[:amount].to_i, currency: @organisation.currency)
    redirect back
  end

  get '/o/:slug/stats' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/stats'
  end

  get '/o/:slug/pmails', provides: [:html, :json] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @_organisation = @organisation
    organisation_admins_only!
    @pmails = @organisation.pmails
    @pmails = @pmails.and(:id.in => Pmail.search(params[:q], @pmails).pluck(:id)) if params[:q]
    case params[:to]
    when 'everyone'
      @pmails = @pmails.and(everyone: true)
    when 'monthly_donors'
      @pmails = @pmails.and(monthly_donors: true)
    when 'not_monthly_donors'
      @pmails = @pmails.and(not_monthly_donors: true)
    when 'facilitators'
      @pmails = @pmails.and(facilitators: true)
    when 'waitlist'
      @pmails = @pmails.and(waitlist: true)
    when 'activity'
      @pmails = @pmails.and(mailable_type: 'Activity')
    when 'activity_tag'
      @pmails = @pmails.and(mailable_type: 'ActivityTag')
    when 'local_group'
      @pmails = @pmails.and(mailable_type: 'LocalGroup')
    when 'event'
      @pmails = @pmails.and(mailable_type: 'Event')
    end
    @scope = "organisation_id=#{@organisation.id}"
    case content_type
    when :html
      @pmails = @pmails.order('created_at desc').paginate(page: params[:page])
      erb :'pmails/pmails'
    when :json
      {
        results: @pmails.only(:subject).map { |pmail| { id: pmail.id.to_s, text: "#{pmail.subject} (id:#{pmail.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/receive_feedback/:f' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find_by(account: current_account) || not_found
    @organisationship.set(receive_feedback: params[:f].to_i == 1)
    redirect back
  end

  get '/o/:slug/subscribed/:organisationship_id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find(params[:organisationship_id]) || not_found
    partial :'organisations/subscribed', locals: { organisationship: @organisationship }
  end

  post '/o/:slug/subscribed/:organisationship_id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find(params[:organisationship_id]) || not_found
    @organisationship.set_unsubscribed!(!params[:subscribed])
    200
  end

  get '/organisationships/:id/notes' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only!
    partial :'organisations/notes', locals: { organisationship: @organisationship }
  end

  post '/organisationships/:id/notes' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only!
    @organisationship.set(notes: params[:notes])
    200
  end

  get '/o/:slug/discount_codes' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @discount_codes = @organisation.discount_codes
    @scope = "organisation_id=#{@organisation.id}"
    erb :'discount_codes/discount_codes'
  end

  get '/o/:slug/carousels' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @carousels = @organisation.carousels.order('o asc')
    erb :'carousels/carousels'
  end

  get '/organisationships/:id/monthly_donation' do
    organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = organisationship.organisation
    organisation_admins_only!
    partial :'organisations/monthly_donation', locals: { organisationship: organisationship }
  end

  post '/organisationships/:id/monthly_donation' do
    organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = organisationship.organisation
    organisation_admins_only!
    organisationship.update_attributes(
      monthly_donation_amount: params[:amount],
      monthly_donation_method: 'Other',
      monthly_donation_currency: @organisation.currency
    )
    200
  end

  get '/organisations/:id/feedback_summary' do
    @organisation = Organisation.find(params[:id]) || not_found
    organisation_admins_only!
    if !admin? && @organisation.feedback_summary_last_refreshed_at && @organisation.feedback_summary_last_refreshed_at > 24.hours.ago
      flash[:error] = 'Feedback summary can only be refreshed once per day'
    else
      @organisation.feedback_summary!
    end
    redirect request.referrer ? "#{request.referrer}#feedback" : back
  end

  get '/organisations/:id/feedback_summary/delete' do
    @organisation = Organisation.find(params[:id]) || not_found
    organisation_admins_only!
    @organisation.set(feedback_summary: nil)
    @organisation.set(feedback_summary_last_refreshed_at: Time.now)
    flash[:notice] = 'Feedback summary removed.'
    redirect request.referrer ? "#{request.referrer}#feedback" : back
  end
end
