Dandelion::App.controller do
  before do
    @event = Event.find(params[:event_id]) || not_found
    @organisation = @event.organisation
    organisation_admins_only!
  end

  get '/events/:event_id/rpayments' do
    @rpayments = @event.rpayments.order('created_at desc')
    @rpayment = @event.rpayments.build(role: params[:role], amount: params[:amount], currency: params[:currency])
    erb :'rpayments/rpayments'
  end

  post '/events/:event_id/rpayments/new' do
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
    @rpayment = @event.rpayments.find(params[:id]) || not_found
    erb :'rpayments/build'
  end

  post '/events/:event_id/rpayments/:id/edit' do
    @rpayment = @event.rpayments.find(params[:id]) || not_found
    if @rpayment.update_attributes(mass_assigning(params[:rpayment], Rpayment))
      redirect "/events/#{params[:event_id]}/rpayments"
    else
      flash.now[:error] = 'There was an error saving the payment'
      erb :'rpayments/build'
    end
  end

  get '/events/:event_id/rpayments/:id/destroy' do
    @rpayment = @event.rpayments.find(params[:id]) || not_found
    @rpayment.destroy
    redirect back
  end
end
