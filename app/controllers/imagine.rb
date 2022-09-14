Dandelion::App.controller do
  get '/imagine' do
    erb :imagine
  end

  post '/imagine' do
    redirect '/imagine'
  end
end
