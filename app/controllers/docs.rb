Dandelion::App.controller do
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
      flash.now[:error] = 'There was an error saving the page.'
      erb :'docs/build'
    end
  end
end
