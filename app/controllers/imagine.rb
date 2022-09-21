Dandelion::App.controller do
  get '/imagine' do
    erb :imagine
  end

  post '/imagine' do
    sign_in_required!
    halt 400, 'Please enter a prompt.' unless params[:prompt]
    halt 400, 'You have reached your limit of 100 generations in the past 24 hours.' if current_account.predictions.and(:created_at.gt => 24.hours.ago).count > 100
    current_account.predictions.create(prompt: params[:prompt]).id.to_s
  end

  get '/imagine/:id' do
    if request.xhr?
      sign_in_required!
      @prediction = Prediction.find(params[:id])
      @prediction.fetch! unless @prediction.finished?
      if @prediction.result['error']
        halt 400, @prediction.result['error']
      elsif @prediction.result['output']
        content_type 'application/json'
        @prediction.result['output'].to_json
      else
        200
      end
    else
      @prediction = Prediction.find(params[:id])
      @f = @prediction.prediction_favs.first.index if @prediction.prediction_favs.count == 1
      erb :imagine
    end
  end

  post '/imagine/:id/:f' do
    sign_in_required!
    @prediction = current_account.predictions.find(params[:id])
    @prediction.prediction_favs.create(index: params[:f])
    200
  end

  get '/imagine/:id/:f' do
    @prediction = Prediction.find(params[:id])
    @prediction_fav = @prediction.prediction_favs.find_by(index: params[:f])
    @f = @prediction_fav.index
    erb :imagine
  end

  get '/imagine/:id/:f/unsave' do
    sign_in_required!
    @prediction = Prediction.find(params[:id])
    halt 400 unless @prediction.account == current_account || admin?
    @prediction.prediction_favs.find_by(index: params[:f]).destroy
    redirect '/imagine'
  end
end
