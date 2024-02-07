Dandelion::App.controller do
  before do
    sign_in_required!
    @account = current_account
  end

  get '/recommendations/accounts' do
    @account.recommend_people! if @account.recommended_people_cache.nil?
    erb :'recommendations/accounts'
  end

  get '/recommendations/events' do
    @account.recommend_people! if @account.recommended_people_cache.nil?
    @account.recommend_events! if @account.recommended_events_cache.nil?
    erb :'recommendations/events'
  end
end
