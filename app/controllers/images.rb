Dandelion::App.controller do
  get '/qr', provides: [:png, :pdf] do
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
    blob = result.to_blob

    # Clean up temp files (only remote images, not local overlay)
    [base_image, result].each { |img| img.destroy! if img.respond_to?(:destroy!) }

    blob
  end
end
