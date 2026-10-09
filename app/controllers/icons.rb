Dandelion::App.controller do
  get '/icons/calendar/:month/:day' do
    content_type 'image/svg+xml'

    month = params[:month].to_s.upcase
    day = params[:day].to_s

    # Validate inputs
    unless month.match?(/^[A-Z]{3}$/) && day.match?(/^\d{1,2}$/)
      status 400
      return 'Invalid month or day format'
    end

    # Generate SVG calendar icon
    partial :'icons/calendar', locals: { month: month, day: day }
  end

  get '/icons/image/:image' do
    image = params[:image].to_s
    # Only names of the icons in app/assets/images/icons, so the parameter can't reach other files
    halt 404 unless image.match?(/\A[a-z0-9-]+\z/) && File.exist?(Padrino.root('app', 'assets', 'images', 'icons', "#{image}.svg"))

    content_type 'image/svg+xml'
    partial :'icons/image', locals: { image: image }
  end
end
