Dandelion::App.controller do
  before do
    admins_only!
  end

  get '/stats/orders' do
    @orders = Order.order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/orders'
  end

  get '/stats/comments' do
    @comments = Comment.and(:body.ne => nil).order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/comments'
  end

  get '/stats/accounts' do
    @accounts = Account.public.order('created_at desc').and(ps_account_id: nil).paginate(page: params[:page], per_page: 50)
    erb :'stats/accounts'
  end

  get '/stats/messages' do
    @messages = Message.order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/messages'
  end
end
