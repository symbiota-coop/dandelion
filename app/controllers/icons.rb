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
    content_type 'image/svg+xml'
    partial :'icons/image', locals: { image: params[:image] }
  end
end
