Dandelion::App.controller do
  get '/books' do
    @title = 'Books'
    @books = Book.all(sort: { 'Original Publication Year or Year Published' => 'desc' }, filter: '{Dandelion} = 1')
    erb :'books/books'
  end

  get '/books/:slug' do
    @book = Book.all(filter: "{Slug} = '#{params[:slug]}'").first || not_found
    @title = "#{@book['Title']} by #{@book['Author']}"
    if @book['Full text'].empty?
      redirect "https://goodreads.com/book/show/#{@book['Book Id']}"
    else
      erb :'books/book'
    end
  end

  get '/films' do
    @title = 'Films'
    @films = Film.all(sort: { 'Year' => 'desc' })
    erb :'films/films'
  end

  get '/treasure-map' do
    @title = 'Treasure Map'
    erb :treasure_map
  end
end
