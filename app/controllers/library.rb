Dandelion::App.controller do
  get '/books' do
    @title = 'Books'
    @books = Book.all(sort: { 'Original Publication Year or Year Published' => 'desc' }, filter: '{Dandelion} = 1')
    erb :'books/books'
  end

  get '/books/:slug', provides: [:html, :jpg] do
    @book = Book.all(filter: "{Slug} = '#{params[:slug]}'").first || not_found
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
    @films = Film.all(sort: { 'Year' => 'desc' })
    erb :'films/films'
  end

  get '/films/:slug', provides: :jpg do
    @film = Film.all(filter: "{Slug} = '#{params[:slug]}'").first || not_found
    redirect @film['Images'].first['url']
  end
end
