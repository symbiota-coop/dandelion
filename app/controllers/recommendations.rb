Dandelion::App.controller do
  before do
    sign_in_required!
    @account = current_account
  end

  # Builds the recommendations on a first visit, before the nightly Event.recommend has, holding a lock on the account
  # so a second request at once (a reload) waits for the first's rather than building them again
  get '/recommendations/people' do
    RecordLock.hold(@account) do
      @account.recommend_people! if @account.recommended_people.nil?
    end
    erb :'recommendations/people'
  end

  get '/recommendations/events' do
    RecordLock.hold(@account) do
      @account.recommend_people! if @account.recommended_people.nil?
      @account.recommend_events! if @account.recommended_events.nil?
    end
    erb :'recommendations/events'
  end
end
