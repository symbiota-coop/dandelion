Dandelion::App.controller do
  # Helper method to handle Airrecord API calls with retry logic for 503 errors
  def airtable_with_retry(max_retries: 3, delay: 1, &block)
    retries = 0
    begin
      yield
    rescue Airrecord::Error => e
      # Check if it's a 503 Service Unavailable error
      if e.message.include?('503') && retries < max_retries
        retries += 1
        sleep(delay * retries) # Exponential backoff
        retry
      else
        # Re-raise the error if it's not a 503 or we've exceeded retries
        raise e
      end
    end
  end

  get '/books' do
    @title = 'Books'
    @books = airtable_with_retry do
      Book.all(sort: { 'Original Publication Year or Year Published' => 'desc' }, filter: '{Dandelion} = 1')
    end
    erb :'books/books'
  end

  get '/books/:slug', provides: [:html, :jpg] do
    @book = airtable_with_retry do
      Book.all(filter: "{Slug} = '#{params[:slug]}'").first
    end || not_found
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
    @films = airtable_with_retry do
      Film.all(sort: { 'Year' => 'desc' })
    end
    erb :'films/films'
  end

  get '/films/:slug', provides: :jpg do
    @film = airtable_with_retry do
      Film.all(filter: "{Slug} = '#{params[:slug]}'").first
    end || not_found
    redirect @film['Images'].first['url']
  end

  get '/treasure-map' do
    @title = 'Treasure Map'
    erb :treasure_map
  end
end
