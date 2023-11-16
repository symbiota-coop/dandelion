Dandelion::App.controller do
  get '/books' do
    @books = Book.all
    erb :'books/books'
  end

  get '/books/:slug' do
    @book = Book.find_by(slug: params[:slug])
    @title = "#{@book.title} by #{@book.book_author.name}"
    erb :'books/book'
  end

  get '/books/:slug/:number' do
    @book = Book.find_by(slug: params[:slug])
    @title = "#{@book.title} by #{@book.book_author.name}"
    @book_chapter = @book.book_chapters.find_by(number: params[:number])
    erb :'books/book_chapter'
  end
end
