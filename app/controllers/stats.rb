Dandelion::App.controller do
  before do
    admins_only!
  end

  get '/stats/feedback' do
    @event_feedbacks = EventFeedback.order('created_at desc')
    erb :'stats/feedback'
  end

  get '/stats/orders' do
    @tickets = Ticket.and(:created_at.gte => 3.months.ago, :price.gt => 0)
    @organisations = Organisation.and(:id.in => Event.and(:id.in => @tickets.pluck(:event_id)).pluck(:organisation_id))
    @orders = Order.order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/orders'
  end

  get '/stats/places' do
    @places = Place.order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/places'
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
