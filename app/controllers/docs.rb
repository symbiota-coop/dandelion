Dandelion::App.controller do
  get '/docs/question' do
    @sent = true
    partial :'docs/question'
  end

  post '/docs/question' do
    sign_in_required!
    halt 400 unless params[:question]

    EmailHelper.send_to_founder(
      subject: "[Question] #{current_account.name}",
      body_text: [
        params[:question],
        '',
        "Account: #{ENV['BASE_URI']}/u/#{current_account.username}",
        "Email: #{current_account.email}"
      ].join("\n"),
      reply_to: current_account.email
    )

    200
  end

  get '/docs' do
    halt unless DocPage.exists?
    redirect "/docs/#{DocPage.order('priority desc').first.slug}"
  end

  get '/docs/:slug' do
    @doc_page = DocPage.find_by(slug: params[:slug]) || not_found
    erb :'docs/doc_page'
  end

  get '/docs/:slug/edit' do
    admins_only!
    @doc_page = DocPage.find_by(slug: params[:slug]) || not_found
    erb :'docs/build'
  end

  post '/docs/:slug/edit' do
    admins_only!
    @doc_page = DocPage.find_by(slug: params[:slug]) || not_found
    if @doc_page.update_attributes(mass_assigning(params[:doc_page], DocPage))
      flash[:notice] = 'The page was saved.'
      redirect "/docs/#{@doc_page.slug}"
    else
      @edit_slug = params[:slug] # Use original slug for form action, not the (possibly invalid) in-memory value
      flash.now[:error] = 'There was an error saving the page.'
      erb :'docs/build'
    end
  end
end
