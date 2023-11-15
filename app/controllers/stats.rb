Dandelion::App.controller do
  before do
    admins_only!
  end

  get '/stats/events' do
    erb :'stats/events'
  end

  get '/stats/feedback' do
    @event_feedbacks = EventFeedback.order('created_at desc')
    @event_feedbacks = @event_feedbacks.where(:id.in => search(EventFeedback, @event_feedbacks, params[:q], 25).map(&:id)) if params[:q]
    @event_feedbacks = @event_feedbacks.where(:rating.ne => 5) if params[:hide_5_stars]
    erb :'stats/feedback'
  end

  get '/stats/orders' do
    @orders = Order.order('created_at desc')
    erb :'stats/orders'
  end

  get '/stats/organisations' do
    @from = params[:from] ? Date.parse(params[:from]) : Date.new(3.months.ago.year, 3.months.ago.month, 1)
    @to = params[:to] ? Date.parse(params[:to]) : Date.new(Date.today.year, Date.today.month, 1) - 1.day
    @min_tickets = params[:min_tickets] ? params[:min_tickets].to_i : 10
    @min_order_value = params[:min_order_value] || 1000
    erb :'stats/organisations'
  end

  get '/stats/places' do
    @places = Place.order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/places'
  end

  get '/stats/comments' do
    @comments = Comment.and(:body.ne => nil).order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/comments'
  end

  get '/stats/accounts' do
    @accounts = Account.public.order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/accounts'
  end

  get '/stats/messages' do
    @messages = Message.order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/messages'
  end
end
