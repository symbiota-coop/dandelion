Dandelion::App.controller do
  get '/zoom_parties' do
    sign_in_required!
    @event = Event.find(params[:event_id]) || not_found
    partial :'events/zoom_party'
  end

  post '/zoomships/create' do
    sign_in_required!
    @event = Event.find(params[:event_id]) || not_found
    @event.zoomships.create account: current_account, local_group_id: params[:local_group_id], link: params[:link]
    redirect back
  end

  get '/zoomships/destroy' do
    sign_in_required!
    @event = Event.find(params[:event_id]) || not_found
    @event.zoomships.find_by(account: current_account).destroy
    redirect back
  end

  get '/zoom_parties/attending' do
    sign_in_required!
    @event = Event.find(params[:event_id]) || not_found
    current_account.tickets.create!(event: @event, zoomship_id: params[:zoomship_id], complementary: true)
    redirect back
  end

  get '/zoom_parties/unattend' do
    sign_in_required!
    @event = Event.find(params[:event_id]) || not_found
    @event.tickets.find_by(account: current_account).destroy
    redirect back
  end
end
