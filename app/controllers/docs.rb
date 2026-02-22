Dandelion::App.controller do
  before do
    @docs_dir = File.expand_path('app/views/docs/md', Padrino.root)
    @doc_order = %w[events organisations gatherings mailer zapier].freeze
  end

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
    first = @doc_order.find { |slug| File.exist?(File.join(@docs_dir, "#{slug}.md")) }
    halt 404 if first.nil?
    redirect "/docs/#{first}"
  end

  get '/docs/:slug' do
    path = File.join(@docs_dir, "#{params[:slug]}.md")
    halt 404 unless File.exist?(path) && @doc_order.include?(params[:slug])

    raw = File.read(path)
    @doc_page = { slug: params[:slug], name: params[:slug].to_s.humanize, raw_content: raw, html_body: md(raw), h2_headings: raw.scan(/^## (.+)$/).flatten.map(&:strip) }

    @doc_pages = @doc_order.filter_map do |slug|
      p = File.join(@docs_dir, "#{slug}.md")
      next unless File.exist?(p)

      r = File.read(p)
      { slug: slug, name: slug.to_s.humanize, h2_headings: r.scan(/^## (.+)$/).flatten.map(&:strip) }
    end

    erb :'docs/doc_page'
  end
end
