Dandelion::App.controller do
  get '/stats/charts' do
    erb :'stats/charts'
  end

  get '/stats/feedback' do
    admins_only!
    @event_feedbacks = EventFeedback.order('created_at desc')
    @event_feedbacks = @event_feedbacks.and(:id.in => search(EventFeedback, @event_feedbacks, params[:q], 25).map(&:id)) if params[:q]
    @event_feedbacks = @event_feedbacks.and(:rating.ne => 5) if params[:hide_5_stars]
    erb :'stats/feedback'
  end

  get '/stats/orders' do
    admins_only!
    @orders = Order.order('created_at desc')
    erb :'stats/orders'
  end

  get '/stats/organisations' do
    admins_only!
    @from = params[:from] ? parse_date(params[:from]) : Date.new(3.months.ago.year, 3.months.ago.month, 1)
    @to = params[:to] ? parse_date(params[:to]) : Date.new(Date.today.year, Date.today.month, 1) - 1.day
    @min_tickets = params[:min_tickets] ? params[:min_tickets].to_i : 10
    @min_order_value = params[:min_order_value] || 1000
    erb :'stats/organisations'
  end

  get '/stats/comments' do
    admins_only!
    @comments = Comment.and(:body.ne => nil).order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/comments'
  end

  get '/stats/accounts' do
    admins_only!
    @accounts = Account.public.order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/accounts'
  end

  get '/stats/messages' do
    admins_only!
    @messages = Message.order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/messages'
  end

  get '/stats/icons' do
    admins_only!
    erb :'stats/icons'
  end
end
