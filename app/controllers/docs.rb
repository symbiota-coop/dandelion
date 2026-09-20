Dandelion::App.controller do
  get '/docs/question' do
    @sent = true
    partial :'docs/question'
  end

  post '/docs/deepwiki' do
    @result = Deepwiki.ask(params[:q], page: params[:wiki])
    redirect "/docs/ask/#{@result.query_id}" if @result

    @title = 'Ask DeepWiki'
    @deepwiki_error = true
    erb :'docs/ask'
  end

  get '/docs/ask/:query_id/answer.json' do
    halt 404 unless Deepwiki.query_id?(params[:query_id])
    @result = Deepwiki.fetch(params[:query_id]) || Deepwiki.pending(params[:query_id])

    content_type :json
    {
      html: deepwiki_answer_html(@result.markdown),
      done: @result.done?,
      failed: @result.failed?,
      source_url: @result.source_url
    }.to_json
  end

  get '/docs/ask/:query_id' do
    halt 404 unless Deepwiki.query_id?(params[:query_id])
    @result = Deepwiki.fetch(params[:query_id]) || Deepwiki.pending(params[:query_id])

    @title = [@result.question, 'Ask DeepWiki'].reject(&:empty?).first
    erb :'docs/ask'
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
    redirect '/docs/events'
  end

  get '/docs/:slug' do
    redirect '/docs/integrations' if %w[zapier mcp].include?(params[:slug])

    names = { 'integrations' => 'Zapier & MCP' }
    pages = %w[events organisations gatherings mailer integrations].filter_map do |slug|
      path = File.expand_path("app/views/docs/md/#{slug}.md", Padrino.root)
      next unless File.exist?(path)

      name = names[slug] || slug.humanize
      page = docs_html(md(File.read(path)), slug: slug, name: name)
      { slug: slug, name: name, html_body: page[:html], headings: page[:headings], sections: page[:sections] }
    end

    @doc_page = pages.find { |page| page[:slug] == params[:slug] }
    halt 404 unless @doc_page

    @doc_pages = pages.map { |page| page.slice(:slug, :name) }
    @doc_search_index = pages.each_with_index.flat_map do |page, page_index|
      page[:sections].map do |section|
        href = section[:headingId] == page[:slug] ? "/docs/#{page[:slug]}" : "/docs/#{page[:slug]}##{section[:headingId]}"
        section.merge(slug: page[:slug], pageName: page[:name], pageIndex: page_index, href: href)
      end
    end

    @title = "#{@doc_page[:name]} · Docs"
    erb :'docs/doc_page'
  end
end
