Dandelion::App.controller do
  get '/qr', provides: :png do
    halt 400 unless params[:url]
    RQRCode::QRCode.new(params[:url]).as_png(border_modules: 0, size: 500).to_blob
  end

  get '/youtube_thumb/:id' do
    # load base image
    begin
      base_image = MiniMagick::Image.open("https://i.ytimg.com/vi/#{params[:id]}/sddefault.jpg")
    rescue OpenURI::HTTPError
      begin
        base_image = MiniMagick::Image.open("https://i.ytimg.com/vi/#{params[:id]}/hqdefault.jpg")
      rescue OpenURI::HTTPError
        halt 404
      end
    end
    base_image = base_image.crop('640x360+0+60')

    # load overlay image
    overlay_image = MiniMagick::Image.open('app/assets/images/youtube.png')

    # calculate coordinates to place the overlay image in the center
    x_coordinate = (base_image.width - overlay_image.width) / 2
    y_coordinate = (base_image.height - overlay_image.height) / 2

    # create a new image which is the result of the composite operation
    result = base_image.composite(overlay_image) do |c|
      c.compose 'Over' # OverCompositeOp
      c.geometry "+#{x_coordinate}+#{y_coordinate}" # place overlay image at calculated coordinates
    end

    content_type 'image/jpeg'
    result.to_blob
  end
end
