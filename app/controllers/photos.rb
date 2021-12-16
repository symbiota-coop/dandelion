Dandelion::App.controller do
  get '/photos/:id' do
    @photo = Photo.find(params[:id]) || not_found
    redirect @photo.url
  end

  post '/photos/new' do
    sign_in_required!
    # TODO: check permissions
    @photo = Photo.create!(image: params[:image], account: current_account, photoable_type: params[:photoable_type], photoable_id: params[:photoable_id])
    redirect @photo.url
  end

  get '/photos/:id/destroy' do
    sign_in_required!
    @photo = Photo.find(params[:id]) || not_found
    halt(403) unless admin? || @photo.account_id == current_account.id
    @photo.destroy
    redirect @photo.url
  end
end
