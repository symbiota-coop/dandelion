Dandelion::App.controller do
  get '/events/:id/rpayments' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @rpayments = @event.rpayments.order('created_at desc')
    @rpayment = @event.rpayments.build
    erb :'rpayments/rpayments'
  end

  post '/events/:event_id/rpayments/new' do
    @event = Event.find(params[:event_id]) || not_found
    event_admins_only!
    @rpayment = @event.rpayments.new(mass_assigning(params[:rpayment], Rpayment))
    @rpayment.account = current_account
    if @rpayment.save
      redirect "/events/#{@event.id}/rpayments"
    else
      flash.now[:error] = 'There was an error saving the payment'
      erb :'rpayments/build'
    end
  end

  get '/events/:event_id/rpayments/:id/edit' do
    @event = Event.find(params[:event_id]) || not_found
    event_admins_only!
    @rpayment = @event.rpayments.find(params[:id]) || not_found
    erb :'rpayments/build'
  end

  post '/events/:event_id/rpayments/:id/edit' do
    @event = Event.find(params[:event_id]) || not_found
    event_admins_only!
    @rpayment = @event.rpayments.find(params[:id]) || not_found
    if @rpayment.update_attributes(mass_assigning(params[:rpayment], Rpayment))
      redirect "/events/#{params[:event_id]}/rpayments"
    else
      flash.now[:error] = 'There was an error saving the payment'
      erb :'rpayments/build'
    end
  end

  get '/events/:event_id/rpayments/:id/destroy' do
    @event = Event.find(params[:event_id]) || not_found
    event_admins_only!
    @rpayment = @event.rpayments.find(params[:id]) || not_found
    @rpayment.destroy
    redirect back
  end
end
