Dandelion::App.controller do
  before do
    sign_in_required!
    @account = current_account
  end

  get '/recommendations/accounts' do
    @account.recommended_people if @account.recommended_people_cache.nil?
    erb :'recommendations/accounts'
  end

  get '/recommendations/events' do
    @account.recommended_people if @account.recommended_people_cache.nil?
    @account.recommended_events if @account.recommended_events_cache.nil?
    erb :'recommendations/events'
  end
end
