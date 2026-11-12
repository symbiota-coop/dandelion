Dandelion::App.controller do
  before do
    sign_in_required!
  end

  get '/messages' do
    if request.xhr?
      cp(:'messages/dropdown', key: "/messages?account_id=#{current_account.id}", expires: 1.minute.from_now)
    else
      erb :'messages/messages'
    end
  end

  # Not under /messages/, where a username is a conversation
  get '/messages_index' do
    partial :'messages/index'
  end

  get '/messages/:username' do
    @account = account_from_params
    if @account.id == current_account.id
      flash[:notice] = "You can't message yourself"
      redirect '/messages'
    end
    MessageReceipt.mark_read!(messenger: @account, messengee: current_account)
    if request.xhr?
      halt 304 if request.env['HTTP_X_PAGELET_STAMP'] == Message.thread_stamp(current_account, @account)
      partial :'messages/thread'
    else
      erb :'messages/messages'
    end
  end

  get '/messages/:username/send' do
    @account = account_from_params
    partial :'messages/send'
  end

  post '/messages/:username/send' do
    messengee = account_from_params
    message = Message.new(body: params[:body], messenger: current_account, messengee: messengee)
    if message.save
      200
    else
      halt 400, message.errors.full_messages.join('; ')
    end
  end
end
