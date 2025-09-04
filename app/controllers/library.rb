Dandelion::App.controller do
  get '/books' do
    @title = 'Books'
    begin
      @books = Book.all(sort: { 'Original Publication Year or Year Published' => 'desc' }, filter: '{Dandelion} = 1')
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, StandardError => e
      Honeybadger.notify(e)
      halt 503, 'Service temporarily unavailable. Please try again later.'
    end
    erb :'books/books'
  end

  get '/books/:slug', provides: [:html, :jpg] do
    begin
      @book = Book.all(filter: "{Slug} = '#{params[:slug]}'").first || not_found
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, StandardError => e
      Honeybadger.notify(e)
      halt 503, 'Service temporarily unavailable. Please try again later.'
    end
    
    @title = "#{@book['Title']} by #{@book['Author']}"

    case content_type
    when :html
      if @book['Summary'].blank?
        redirect "https://goodreads.com/book/show/#{@book['Book Id']}"
      else
        erb :'books/book'
      end
    when :jpg
      redirect @book['Cover image'][0]['url']
    end
  end

  get '/films' do
    @title = 'Films'
    begin
      @films = Film.all(sort: { 'Year' => 'desc' })
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, StandardError => e
      Honeybadger.notify(e)
      halt 503, 'Service temporarily unavailable. Please try again later.'
    end
    erb :'films/films'
  end

  get '/films/:slug', provides: :jpg do
    begin
      @film = Film.all(filter: "{Slug} = '#{params[:slug]}'").first || not_found
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, StandardError => e
      Honeybadger.notify(e)
      halt 503, 'Service temporarily unavailable. Please try again later.'
    end
    redirect @film['Images'].first['url']
  end

  get '/treasure-map' do
    @title = 'Treasure Map'
    erb :treasure_map
  end
end
