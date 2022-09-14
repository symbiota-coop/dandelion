Dandelion::App.controller do
  before do
    sign_in_required!
    @replicate = Faraday.new(
      url: 'https://api.replicate.com/v1',
      headers: { 'Authorization': "Token #{ENV['REPLICATE_API_KEY']}", 'Content-Type': 'application/json' }
    )
  end
  get '/imagine' do
    erb :imagine
  end

  post '/imagine' do
    version = 'a9758cbfbd5f3c2094457d996681af52552901775aa2d6dd0b17fd15df959bef'
    width = 512
    height = 512
    halt 400, 'Please enter a prompt' unless params[:prompt]

    prediction = @replicate.post('predictions') do |req|
      req.body = { version: version, input: { width: width, height: height, prompt: params[:prompt] } }.to_json
    end

    JSON.parse(prediction.body)['id']
  end

  get '/imagine/:id' do
    prediction = @replicate.get("predictions/#{params[:id]}")
    json = JSON.parse(prediction.body)
    if json['error']
      halt 400, json['error']
    elsif !(output = json['output'])
      200
    else
      output.first
    end
  end
end
