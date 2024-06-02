Dandelion::App.controller do
  get '/books' do
    @books = Book.all(sort: { 'Original Publication Year or Year Published' => 'desc' }, filter: '{Dandelion} = 1')
    erb :'books/books'
  end

  get '/books/:slug' do
    @book = Book.all(filter: "{Slug} = '#{params[:slug]}'").first || not_found
    @title = "#{@book['Title']} by #{@book['Author']}"
    erb :'books/book'
  end

  get '/films' do
    @title = 'Films'
    erb :'films/films'
  end
end
