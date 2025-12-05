Dandelion::App.controller do
  get '/organisations', provides: %i[html json] do
    @organisations = Organisation.and(hidden: false)
    @organisations = params[:order] == 'created_at' ? @organisations.order('created_at desc') : @organisations.order('followers_count desc')
    @organisations = @organisations.and(:id.in => current_account.organisations_following.pluck(:id)) if current_account && params[:following]
    @organisations = @organisations.and(:id.in => Organisation.search(params[:q], @organisations).pluck(:id)) if params[:q]

    case content_type
    when :html
      @organisations = @organisations.paginate(page: params[:organisations_page], per_page: 50)
      erb :'organisations/organisations'
    when :json
      map_json(@organisations)
    end
  end

  get '/organisations/autocomplete', provides: :json do
    @organisations = Organisation.all.order('created_at desc')
    @organisations = @organisations.and(:id.in => Organisation.search(params[:q], @organisations).pluck(:id)) if params[:q]
    @organisations = @organisations.and(id: params[:id]) if params[:id]
    {
      results: @organisations.map { |organisation| { id: organisation.id.to_s, text: "#{organisation.name} (#{organisation.slug})" } }
    }.to_json
  end

  get '/o/:slug/activities', provides: %i[html json] do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @activities = @organisation.activities.order('name asc')
    @activities = @activities.and(:id.in => Activity.search(params[:q], @activities).pluck(:id)) if params[:q]
    @activities = @activities.and(id: params[:id]) if params[:id]
    case content_type
    when :html
      @activities = @activities.active
      if request.xhr?
        partial :'organisations/activities'
      else
        erb :'organisations/activities'
      end
    when :json
      {
        results: @activities.map { |activity| { id: activity.id.to_s, text: "#{activity.name} (id:#{activity.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/local_groups', provides: %i[html json] do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @local_groups = @organisation.local_groups.order('name asc')
    @local_groups = @local_groups.and(:id.in => LocalGroup.search(params[:q], @local_groups).pluck(:id)) if params[:q]
    @local_groups = @local_groups.and(id: params[:id]) if params[:id]
    case content_type
    when :html
      if request.xhr?
        partial :'organisations/local_groups'
      else
        erb :'organisations/local_groups'
      end
    when :json
      {
        results: @local_groups.map { |local_group| { id: local_group.id.to_s, text: "#{local_group.name} (id:#{local_group.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/news' do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @pmails = @organisation.news
    if request.xhr?
      partial :'organisations/news'
    else
      erb :'organisations/news', layout: (params[:minimal] ? 'minimal' : nil)
    end
  end

  get '/o/:slug/news/latest' do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @pmails = @organisation.news
    redirect "/pmails/#{@pmails.first.id}"
  end

  get '/o/new' do
    sign_in_required!
    @organisation = current_account.organisations.build(params[:organisation])
    erb :'organisations/build'
  end

  post '/o/new' do
    sign_in_required!
    @organisation = current_account.organisations.build(params[:organisation])
    @organisation.show_details_table_in_ticket_emails = true
    @organisation.show_sign_in_link_in_ticket_emails = true
    @organisation.show_ticketholder_link_in_ticket_emails = true
    if @organisation.save
      redirect "/o/#{@organisation.slug}/edit?created=1&tab=payments"
    else
      flash.now[:error] = 'There was an error saving the organisation.'
      erb :'organisations/build'
    end
  end

  get '/o/:slug' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @title = @organisation.name
    erb :'organisations/organisation'
  end

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
        if @organisation.events.count == 0
          "/events/new?organisation_id=#{@organisation.id}&new_org=1"
        elsif current_account.organisations.count == 1
          "/o/#{@organisation.slug}"
        else
          "/o/#{@organisation.slug}/edit"
        end
      )
    else
      flash.now[:error] = 'There was an error saving the organisation.'
      erb :'organisations/build'
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

  get '/o/:slug/carousels/:id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    if params[:id] == 'featured'
      partial :'events/carousel', locals: { title: 'Featured', events: @organisation.featured_events, hide_featured_title: params[:hide_featured_title], skip_margin: true }
    else
      carousel = @organisation.carousels.find(params[:id]) || not_found
      partial :'events/carousel', locals: { title: carousel.name, events: carousel.events(minimal: params[:minimal]) }
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
      @organisation.organisationships.create! account: @account
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

  get '/o/:slug/organisationship' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    case params[:f]
    when 'not_following'
      organisationship = current_account.organisationships.find_by(organisation: @organisation)
      organisationship.destroy if organisationship && !organisationship.admin? && !organisationship.monthly_donor?
    when 'follow_without_subscribing'
      organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
      organisationship.set_unsubscribed!(true)
    when 'follow_and_subscribe'
      organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
      organisationship.set_unsubscribed!(false)
    end
    if request.xhr?
      partial :'organisations/organisationship', locals: { organisation: @organisation, membership_toggle: params[:membership_toggle], btn_class: params[:btn_class] }
    else
      redirect "/o/#{@organisation.slug}"
    end
  end

  get '/o/:slug/unsubscribe' do
    @account = current_account || (params[:account_id] && Account.find(params[:account_id])) || sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    erb :'organisations/unsubscribe'
  end

  post '/o/:slug/unsubscribe' do
    @account = current_account || (params[:account_id] && Account.find(params[:account_id])) || sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = @account.organisationships.find_by(organisation: @organisation) || @account.organisationships.create(organisation: @organisation)
    @organisationship.set_unsubscribed!(true)
    if params[:account_id]
      @unsubscribed = true
      erb :'organisations/unsubscribe'
    else
      flash[:notice] = "You were unsubscribed from #{@organisation.name}."
      redirect '/accounts/subscriptions'
    end
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
    @organisationships = @organisation.organisationships.order('created_at desc')
    @organisationships = @organisationships.and(:account_id.in => Account.search(params[:q], @organisation.members).pluck(:id)) if params[:q]
    @organisationships = @organisationships.and(:monthly_donation_method.ne => nil) if params[:monthly_donor]
    @organisationships = @organisationships.and(monthly_donation_method: nil) if params[:not_a_monthly_donor]
    @organisationships = @organisationships.and(:stripe_connect_json.ne => nil) if params[:connected_to_stripe]
    @organisationships = @organisationships.and(:account_id.in => @organisation.subscribed_accounts.pluck(:id)) if params[:subscribed_to_mailer]
    case content_type
    when :html
      erb :'organisations/followers'
    when :csv
      @organisation.send_followers_csv(current_account)
      flash[:notice] = 'You will receive the CSV via email shortly.'
      redirect back
    end
  end

  get '/o/:slug/subscribed_accounts_count' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisation.subscribed_accounts_count.to_s
  end

  get '/o/:slug/monthly_donors_count' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisation.monthly_donors_count.to_s
  end

  get '/o/:slug/monthly_donations_count' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisation.monthly_donations_count.to_s
  end

  post '/o/:slug/followers' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation.import_from_csv(File.read(params[:csv]), :organisationships)
    flash[:notice] = 'The followers will be added shortly. Refresh the page to check progress.'
    redirect "/o/#{@organisation.slug}/followers"
  end

  get '/o/:slug/via/:username' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @account = Account.find_by(username: params[:username]) || not_found
    @og_image = @organisation.affiliate_share_image_url
    @fulltitle = "#{@account.name} invites you to become a member of #{@organisation.name}"
    erb :'organisations/referral'
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

  post '/organisationships/:id/referrer' do
    sign_in_required!
    @organisationship = current_account.organisationships.find(params[:id]) || not_found
    @organisationship.hide_referrer = nil
    @organisationship.referrer_id = params[:organisationship][:referrer_id]
    @organisationship.save
    redirect back
  end

  get '/organisationships/:id/hide_referrer' do
    sign_in_required!
    @organisationship = current_account.organisationships.find(params[:id]) || not_found
    @organisationship.hide_referrer = true
    @organisationship.save
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
        results: @pmails.map { |pmail| { id: pmail.id.to_s, text: "#{pmail.subject} (id:#{pmail.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/show_membership/:f' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = @organisation.organisationships.find_by(account: current_account) || not_found
    @organisationship.set(hide_membership: params[:f].to_i == 0)
    redirect back
  end

  get '/o/:slug/show_feedback' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    if request.xhr? || params[:minimal]
      partial :'event_feedbacks/event_feedbacks', locals: { event_feedbacks: @organisation.unscoped_event_feedbacks }, layout: (params[:minimal] ? 'minimal' : false)
    else
      redirect "/o/#{@organisation.slug}"
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
