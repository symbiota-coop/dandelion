Dandelion::App.controller do
  get '/events/:id/rpayments' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @rpayments = @event.rpayments.order('created_at desc')
    erb :'rpayments/rpayments'
  end

  post '/events/:event_id/rpayments/new' do
    @event = Event.find(params[:event_id]) || not_found
    event_admins_only!
    @rpayment = @event.rpayments.new(mass_assigning(params[:rpayment], Rpayment))
    @rpayment.payer = current_account
    if @rpayment.save
      redirect "/events/#{@event.id}/rpayments"
    else
      flash[:error] = 'There was an error saving the payment'
      redirect back
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
