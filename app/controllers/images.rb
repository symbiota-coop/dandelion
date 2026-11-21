Dandelion::App.controller do
  get '/qr', provides: [:png, :pdf], access: :public do
    halt 400 unless params[:url]
    case content_type
    when :pdf
      unit = 2.83466666667 # units / mm
      cm = 10 * unit
      page_size = 15 * cm # square page size
      qr_size = page_size
      Prawn::Document.new(page_size: [page_size, page_size], margin: 0) do |pdf|
        pdf.print_qr_code params[:url], extent: qr_size, stroke: false
      end.render
    else
      RQRCode::QRCode.new(params[:url]).as_png(border_modules: 0, size: 500).to_blob
    end
  end

  # Gravatar's fallback for accounts with no image (see Account#gravatar_url): the initials are in the path rather
  # than looked up, so it needs no query, and a new name is a new URL, which Gravatar hasn't cached. Gravatar and
  # browsers keep these for a year, so when the image changes, bump the version here and in Account#generated_avatar_path
  get '/avatar/v2', provides: :png, access: :public do
    cache_control :public, max_age: 1.year.to_i
    Account.avatar_png
  end

  get '/avatar/v2/:initials', provides: :png, access: :public do
    halt 404 unless params[:initials].match?(AccountAvatar::INITIALS)
    cache_control :public, max_age: 1.year.to_i
    Account.avatar_png(params[:initials])
  end

  get '/youtube_thumb/:id', access: :public do
    halt 400 unless params[:id] =~ /\A[A-Za-z0-9_-]{11}\z/

    # The larger thumbnail (640x480), or the smaller (480x360) for videos without one
    response = %w[sddefault hqdefault].lazy.map do |size|
      Faraday.get("https://i.ytimg.com/vi/#{params[:id]}/#{size}.jpg") do |request|
        request.options.open_timeout = 5
        request.options.timeout = 10
      end
    end.find(&:success?)
    halt 404 unless response

    thumbnail = begin
      Vips::Image.new_from_buffer(response.body, '')
    rescue Vips::Error
      nil
    end
    # Only a JPEG, as YouTube serves them
    halt 404 unless thumbnail&.get('vips-loader') == 'jpegload_buffer'

    # 16:9, from 60px down, with the play button in the middle
    thumbnail = thumbnail.crop(0, 60, [640, thumbnail.width].min, [360, thumbnail.height - 60].min)
    play = Vips::Image.new_from_file(Padrino.root('app/assets/images/youtube.png').to_s)
    thumbnail = thumbnail.composite2(play, :over, x: (thumbnail.width - play.width) / 2, y: (thumbnail.height - play.height) / 2)

    content_type 'image/jpeg'
    thumbnail.flatten.write_to_buffer('.jpg', Q: 90, keep: :none)
  end
end
