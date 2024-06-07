Dandelion::App.controller do
  before do
    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id]) || not_found
      @scope = "organisation_id=#{@organisation.id}"
      organisation_admins_only!
      @discount_codes = @organisation.discount_codes
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id]) || not_found
      @scope = "activity_id=#{@activity.id}"
      activity_admins_only!
      @discount_codes = @activity.discount_codes
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @scope = "local_group_id=#{@local_group.id}"
      local_group_admins_only!
      @discount_codes = @local_group.discount_codes
    elsif params[:event_id]
      @event = Event.find(params[:event_id]) || not_found
      @scope = "event_id=#{@event.id}"
      event_admins_only!
      @discount_codes = @event.discount_codes
    else
      kick!
    end
  end

  get '/discount_codes/new' do
    @discount_code = DiscountCode.new
    if @organisation
      @discount_code.fixed_discount_currency = @organisation.currency
    elsif @activity
      @discount_code.fixed_discount_currency = @activity.organisation.currency
    elsif @local_group
      @discount_code.fixed_discount_currency = @local_group.organisation.currency
    elsif @event
      @discount_code.fixed_discount_currency = @event.currency
    end
    erb :'discount_codes/build'
  end

  post '/discount_codes/new' do
    @discount_code = DiscountCode.new(mass_assigning(params[:discount_code], DiscountCode))
    @discount_code.account = current_account
    if @organisation
      @discount_code.codeable = @organisation
    elsif @activity
      @discount_code.codeable = @activity
    elsif @local_group
      @discount_code.codeable = @local_group
    elsif @event
      @discount_code.codeable = @event
    end
    if @discount_code.save
      flash[:notice] = %(The discount code was saved.)
      if @organisation
        redirect "/o/#{@organisation.slug}/discount_codes"
      elsif @activity
        redirect "/activities/#{@activity.id}/discount_codes"
      elsif @local_group
        redirect "/local_groups/#{@local_group.id}/discount_codes"
      elsif @event
        redirect "/events/#{@event.id}/discount_codes"
      end
    else
      erb :'discount_codes/build'
    end
  end

  get '/discount_codes/:discount_code_id/edit' do
    @discount_code = @discount_codes.find(params[:discount_code_id]) || not_found
    erb :'discount_codes/build'
  end

  post '/discount_codes/:discount_code_id/edit' do
    @discount_code = @discount_codes.find(params[:discount_code_id]) || not_found
    if @discount_code.update_attributes(mass_assigning(params[:discount_code], DiscountCode))
      flash[:notice] = 'The discount code was saved.'
      if @organisation
        redirect "/o/#{@organisation.slug}/discount_codes"
      elsif @activity
        redirect "/activities/#{@activity.id}/discount_codes"
      elsif @local_group
        redirect "/local_groups/#{@local_group.id}/discount_codes"
      elsif @event
        redirect "/events/#{@event.id}/discount_codes"
      end
    else
      erb :'discount_codes/build'
    end
  end

  get '/discount_codes/:discount_code_id/destroy' do
    @discount_code = @discount_codes.find(params[:discount_code_id]) || not_found
    @discount_code.destroy
    if @organisation
      redirect "/o/#{@organisation.slug}/discount_codes"
    elsif @activity
      redirect "/activities/#{@activity.id}/discount_codes"
    elsif @local_group
      redirect "/local_groups/#{@local_group.id}/discount_codes"
    elsif @event
      redirect "/events/#{@event.id}/discount_codes"
    end
  end
end
