Dandelion::App.controller do
  get '/api/resources' do
    api_account!
    api_respond { Dandelion::API.describe }
  end

  post '/api/:resource/find' do
    account = api_account!
    body = api_body
    api_respond do
      Dandelion::API.find(account, params[:resource], filter: body['filter'], fields: body['fields'], sort: body['sort'], limit: body['limit'], skip: body['skip'])
    end
  end

  post '/api/:resource/count' do
    account = api_account!
    body = api_body
    api_respond { Dandelion::API.count(account, params[:resource], filter: body['filter']) }
  end

  get '/api/:resource/:id' do
    account = api_account!
    api_respond { Dandelion::API.get(account, params[:resource], params[:id]) }
  end
end
