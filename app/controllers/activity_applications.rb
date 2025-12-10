Dandelion::App.controller do
  get '/activities/:id/apply' do
    @activity = Activity.find(params[:id]) || not_found
    @activityship = @activity.activityships.find_by(account: current_account)
    #  redirect "/activities/#{@activity.id}/join" if @activity.privacy == 'open'
    @account = current_account || Account.new
    erb :'activity_applications/apply'
  end

  post '/activities/:id/apply' do
    @activity = Activity.find(params[:id]) || not_found

    if (account = Account.find_by(email: params[:account][:email].downcase))
      @account = account
      unless @account.update_attributes(mass_assigning(params[:account].map { |k, v| [k, v] if v }.compact.to_h, Account))
        flash.now[:error] = 'There was a problem saving the application'
        halt 400, erb(:'activity_applications/apply')
      end
    else
      @account = Account.new(mass_assigning(params[:account], Account))
      unless @account.save
        flash.now[:error] = 'There was a problem saving the application'
        halt 400, erb(:'activity_applications/apply')
      end
    end

    if @activity.activityships.find_by(account: @account)
      flash[:notice] = "You're already part of that activity"
      redirect back
    else
      @activity_application = @activity.activity_applications.build(account: @account, via: params[:via], status: 'Pending', answers: (params[:answers].map { |i, x| [params[:questions][i], (x unless x == 'false')] } if params[:answers] && params[:questions]))
      if @activity_application.save
        redirect "/activities/#{@activity.id}/apply?applied=true"
      else
        flash.now[:error] = 'There was a problem saving the application'
        halt 400, erb(:'activity_applications/apply')
      end
    end
  end

  get '/activities/:id/applications', provides: %i[html csv] do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @from = parse_date(params[:from]) if params[:from]
    @to = parse_date(params[:to]) if params[:to]
    @activity_applications = @activity.activity_applications.includes(:account)
    @activity_applications = @activity_applications.and(:account_id.in => Account.search(params[:q], child_scope: @activity_applications).pluck(:id)) if params[:q]
    @activity_applications = @activity_applications.and(:word_count.gte => params[:min_word_count]) if params[:min_word_count]
    @activity_applications = @activity_applications.and(:word_count.lte => params[:max_word_count]) if params[:max_word_count]
    @activity_applications = @activity_applications.and(:account_id.in => @activity.applicants.and(has_image: true).pluck(:id)) if params[:photo]
    @activity_applications = @activity_applications.and(:account_id.in => @activity.applicants.and(:location.ne => nil).pluck(:id)) if params[:location]
    @gender = params[:gender] || 'All'
    @activity_applications = case @gender
                             when 'All'
                               @activity_applications
                             when 'Man'
                               @activity_applications.and(:account_id.in => @activity.applicants.and(:gender.in => ['Man', 'Cis Man']).pluck(:id))
                             when 'Woman'
                               @activity_applications.and(:account_id.in => @activity.applicants.and(:gender.in => ['Woman', 'Cis Woman']).pluck(:id))
                             else
                               @activity_applications.and(:account_id.in => @activity.applicants.and(:gender.nin => ['Man', 'Woman', 'Cis Man', 'Cis Woman']).pluck(:id))
                             end
    @status = params[:status] || 'Pending'
    @activity_applications = @activity_applications.and(status: @status) unless @status == 'All'
    @activity_applications = @activity_applications.and(statused_by: params[:statused_by]) if params[:statused_by]
    @activity_applications = @activity_applications.and(:created_at.gte => @from) if @from
    @activity_applications = @activity_applications.and(:created_at.lt => @to + 1) if @to
    @order = params[:order] || 'created_at'
    @activity_applications = @activity_applications.order("#{@order} desc")
    @points = @activity_applications.and(:account_id.in => @activity.applicants.and(:coordinates.ne => nil).pluck(:id))
    case content_type
    when :html
      erb :'activity_applications/activity_applications'
    when :csv
      @activity.send_applications_csv(current_account)
      flash[:notice] = 'You will receive the CSV via email shortly.'
      redirect back
    end
  end

  get '/activities/:id/activity_applications/latest' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    @activity_application = @activity.activity_applications.order('created_at desc').and(account_id: current_account.id).first || not_found
    @account = @activity_application.account
    erb :'activity_applications/view'
  end

  get '/activities/:id/activity_applications/:activity_application_id' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activity_application = @activity.activity_applications.find(params[:activity_application_id]) || not_found
    @account = @activity_application.account
    erb :'activity_applications/activity_application'
  end

  get '/activities/:id/activity_applications/:activity_application_id/set_status' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activity_application = @activity.activity_applications.find(params[:activity_application_id]) || not_found
    partial :'activity_applications/set_status'
  end

  post '/activities/:id/activity_applications/:activity_application_id/set_status' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activity_application = @activity.activity_applications.find(params[:activity_application_id]) || not_found
    @activity_application.status = params[:status]
    @activity_application.accept if @activity_application.status == 'Accepted'
    @activity_application.statused_by = current_account
    @activity_application.statused_at = Time.now
    @activity_application.save
    200
  end

  get '/activities/:id/activity_applications/:activity_application_id/destroy' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activity_application = @activity.activity_applications.find(params[:activity_application_id]) || not_found
    @activity_application.destroy
    redirect back
  end
end
