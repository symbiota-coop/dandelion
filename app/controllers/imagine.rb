Dandelion::App.controller do
  before do
    sign_in_required!
  end
  get '/imagine' do
    erb :imagine
  end

  post '/imagine' do
    halt 400, 'Please enter a prompt.' unless params[:prompt]
    halt 400, 'You have reached your limit of 100 generations in the past 24 hours.' if current_account.predictions.and(:created_at.gt => 24.hours.ago).count > 100
    current_account.predictions.create(prompt: params[:prompt]).id.to_s
  end

  get '/imagine/:id' do
    if request.xhr?
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
      @f = @prediction.favs.first if @prediction.favs.count == 1
      erb :imagine
    end
  end

  post '/imagine/:id/:f' do
    @prediction = Prediction.find(params[:id])
    @prediction.favs ||= []
    @prediction.favs << params[:f].to_i unless @prediction.favs.include?(params[:f].to_i)
    @prediction.save
    200
  end

  get '/imagine/:id/:f' do
    @prediction = Prediction.find(params[:id])
    @f = params[:f].to_i
    erb :imagine
  end

  get '/imagine/:id/:f/unsave' do
    @prediction = Prediction.find(params[:id])
    @prediction.favs = @prediction.favs - [params[:f].to_i]
    @prediction.save
    redirect '/imagine'
  end
end
