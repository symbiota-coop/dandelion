Dandelion::App.controller do
  get '/u/:username/unsubscribe' do
    sign_in_required!
    @account = Account.find_by(username: params[:username]) || not_found
    @follow = current_account.follows_as_follower.find_by(followee: @account) || current_account.follows_as_follower.create(followee: @account)
    @follow.update_attribute(:unsubscribed, true)
    flash[:notice] = "You were unsubscribed from #{@account.name}."
    redirect "/u/#{@account.username}"
  end

  get '/follow/:id' do
    sign_in_required!
    @account = Account.find(params[:id]) || not_found
    case params[:f]
    when 'not_following'
      current_account.follows_as_follower.find_by(followee: @account).try(:destroy)
    when 'follow_without_subscribing'
      follow = current_account.follows_as_follower.find_by(followee: @account) || current_account.follows_as_follower.create(followee: @account)
      follow.update_attribute(:unsubscribed, true)
    when 'follow_and_subscribe'
      follow = current_account.follows_as_follower.find_by(followee: @account) || current_account.follows_as_follower.create(followee: @account)
      follow.update_attribute(:unsubscribed, false)
    end
    request.xhr? ? (partial :'accounts/follow', locals: { account: @account, btn_class: params[:btn_class] }) : redirect("/u/#{@account.username}")
  end

  get '/follow/starred/:id' do
    sign_in_required!
    follow = current_account.follows_as_follower.find(params[:id])
    partial :'accounts/star', locals: { follow: follow, btn_class: params[:btn_class] }
  end

  get '/follow/star/:id' do
    sign_in_required!
    follow = current_account.follows_as_follower.find(params[:id])
    follow.update_attribute(:starred, true)
    200
  end

  get '/follow/unstar/:id' do
    sign_in_required!
    follow = current_account.follows_as_follower.find(params[:id])
    follow.update_attribute(:starred, nil)
    200
  end
end
