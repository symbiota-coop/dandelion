Dandelion::App.controller do
  before do
    sign_in_required!
    @account = current_account
  end

  get '/recommendations/people' do
    @account.recommend_people! if @account.recommended_people.nil?
    erb :'recommendations/people'
  end

  get '/recommendations/events' do
    @account.recommend_people! if @account.recommended_people.nil?
    @account.recommend_events! if @account.recommended_events.nil?
    erb :'recommendations/events'
  end
end
