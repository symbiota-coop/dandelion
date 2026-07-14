Dandelion::App.controller do
  get '/books' do
    @title = 'Books'
    @books = library_books.select { |b| b[:dandelion] == 'true' }.sort_by { |b| -b[:original_publication_year_or_year_published].to_i }
    erb :'books/books'
  end

  get '/books/:slug', provides: [:html, :jpg] do
    @book = library_books.find { |b| b[:slug] == params[:slug] } || not_found
    @title = "#{@book[:title]} by #{@book[:author]}"

    case content_type
    when :html
      if @book[:summary].blank?
        redirect "https://goodreads.com/book/show/#{@book[:book_id]}"
      else
        erb :'books/book'
      end
    when :jpg
      redirect library_image_url(@book[:cover_image])
    end
  end

  get '/films' do
    @title = 'Films'
    @films = library_films.sort_by { |f| -f[:year].to_i }
    erb :'films/films'
  end

  get '/films/:slug', provides: :jpg do
    @film = library_films.find { |f| f[:slug] == params[:slug] } || not_found
    redirect library_image_url(@film[:image])
  end
end
