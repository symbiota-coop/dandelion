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

    extract_headings = lambda do |content|
      headings = []
      current_h2 = nil
      content.each_line do |line|
        if line =~ /^## (.+)$/
          current_h2 = { text: ::Regexp.last_match(1).strip, h3s: [] }
          headings << current_h2
        elsif line =~ /^### (.+)$/ && current_h2
          current_h2[:h3s] << ::Regexp.last_match(1).strip
        end
      end
      headings
    end

    @doc_page = { slug: params[:slug], name: params[:slug].to_s.humanize, raw_content: raw, html_body: md(raw), headings: extract_headings.call(raw) }

    @doc_pages = @doc_order.filter_map do |slug|
      p = File.join(@docs_dir, "#{slug}.md")
      next unless File.exist?(p)

      r = File.read(p)
      { slug: slug, name: slug.to_s.humanize, headings: extract_headings.call(r) }
    end

    erb :'docs/doc_page'
  end
end
