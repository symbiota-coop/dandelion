Dandelion::App.controller do
  get '/stats/comments' do
    admins_only!
    @comments = Comment.order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/comments'
  end

  get '/stats/accounts' do
    admins_only!
    @accounts = Account.public.order('created_at desc').and(ps_account_id: nil).paginate(page: params[:page], per_page: 50)
    erb :'stats/accounts'
  end

  get '/stats/messages' do
    admins_only!
    @messages = Message.order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/messages'
  end
end
