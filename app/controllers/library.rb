Dandelion::App.controller do
  get '/books' do
    @title = 'Books'
    @books = Library.books.sort_by { |b| -b[:original_publication_year_or_year_published].to_i }
    erb :'books/books'
  end

  get '/books/:slug', provides: [:html, :jpg] do
    @book = Library.books.find { |b| b[:slug] == params[:slug] } || not_found

    case content_type
    when :html
      redirect "https://goodreads.com/book/show/#{@book[:book_id]}"
    when :jpg
      redirect library_image_url(@book[:cover_image])
    end
  end

  get '/films' do
    @title = 'Films'
    @films = Library.films.sort_by { |f| -f[:year].to_i }
    erb :'films/films'
  end

  get '/films/:slug', provides: :jpg do
    @film = Library.films.find { |f| f[:slug] == params[:slug] } || not_found
    redirect library_image_url(@film[:image])
  end
end
