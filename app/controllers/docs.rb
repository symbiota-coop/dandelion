Dandelion::App.controller do
  get '/docs/question' do
    @sent = true
    partial :'docs/question'
  end

  post '/docs/question' do
    sign_in_required!
    halt 400 unless params[:question]

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "[Question] #{current_account.name}"
    batch_message.body_text "#{params[:question]}\n\nAccount: #{ENV['BASE_URI']}/u/#{current_account.username}\nEmail: #{current_account.email}"
    batch_message.reply_to current_account.email

    batch_message.add_recipient(:to, ENV['FOUNDER_EMAIL'])

    batch_message.finalize if Padrino.env == :production

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
      flash.now[:error] = 'There was an error saving the page.'
      erb :'docs/build'
    end
  end
end
