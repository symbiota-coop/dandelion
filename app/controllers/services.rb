Dandelion::App.controller do
  get '/services/new' do
    sign_in_required!
    @service = Service.new
    @service.organisation = Organisation.find(params[:organisation_id]) || not_found if params[:organisation_id]
    @service.refund_deleted_orders = true
    redirect '/organisations' unless @service.organisation
    service_admins_only!
    @service.currency = @service.organisation.currency
    erb :'services/build'
  end

  post '/services/new' do
    @service = Service.new(mass_assigning(params[:service], Service))
    service_admins_only!
    if @service.save
      redirect "/services/#{@service.id}"
    else
      flash.now[:error] = 'There was an error saving the service'
      erb :'services/build'
    end
  end

  post '/services/:id/edit' do
    @service = Service.find(params[:id]) || not_found
    service_admins_only!
    if @service.update_attributes(mass_assigning(params[:service], Service))
      flash[:notice] = 'The service was saved.'
      redirect "/services/#{@service.id}"
    else
      flash.now[:error] = 'There was an error saving the service.'
      erb :'services/build'
    end
  end

  get '/services/:id/edit' do
    @service = Service.find(params[:id]) || not_found
    service_admins_only!
    erb :'services/build'
  end

  get '/services/:id' do
    @service = Service.find(params[:id]) || not_found
    service_admins_only! if @service.draft?
    @booking = @service.bookings.new
    erb :'services/service'
  end

  get '/services/:id/bookings', provides: %i[html csv pdf] do
    @service = Service.find(params[:id]) || not_found
    service_admins_only!
    @bookings = @service.bookings
    if params[:q]
      @bookings = @bookings.and(:account_id.in => Account.all.or(
        { name: /#{::Regexp.escape(params[:q])}/i },
        { email: /#{::Regexp.escape(params[:q])}/i }
      ).pluck(:id))
    end
    v = service_admin?
    case content_type
    when :html
      erb :'services/bookings'
    when :csv
      CSV.generate do |csv|
        csv << %w[name email value created_at]
        @bookings.each do |booking|
          csv << [
            booking.account.name,
            v ? booking.account.email : '',
            m((booking.value || 0), booking.currency),
            booking.created_at.to_s(:db)
          ]
        end
      end
    when :pdf
      @bookings = @bookings.sort_by { |booking| booking.account.name }
      Prawn::Document.new do |pdf|
        pdf.font "#{Padrino.root}/app/assets/fonts/circular-ttf/CircularStd-Book.ttf"
        pdf.table([%w[name email value created_at]] +
            @bookings.map do |booking|
              [
                booking.account.name,
                v ? booking.account.email : '',
                m((booking.value || 0), booking.currency),
                booking.created_at.to_s(:db)
              ]
            end)
      end.render
    end
  end

  get '/services/:id/stats' do
    @service = Service.find(params[:id]) || not_found
    service_admins_only!
    partial :'services/service_stats_row', locals: { service: @service }
  end

  get '/services/:id/day/:date' do
    @service = Service.find(params[:id]) || not_found
    partial :'services/day', locals: { date: Date.parse(params[:date]) }
  end

  get '/services/:id/booking_email' do
    @service = Service.find(params[:id]) || not_found
    service_admins_only!
    erb :'services/booking_email'
  end

  get '/services/:id/booking_email_preview' do
    @service = Service.find(params[:id]) || not_found
    service_admins_only!
    service = @service
    booking = @service.bookings.new
    booking.start_time = Time.now
    booking.end_time = Time.now + 1.hour
    add_to_calendar = ERB.new(File.read(Padrino.root('app/views/services/_add_to_calendar.erb'))).result(binding)
    account = current_account
    content = ERB.new(File.read(Padrino.root('app/views/emails/booking.erb'))).result(binding)
                 .gsub('%recipient.firstname%', current_account.firstname)
                 .gsub('%recipient.token%', current_account.sign_in_token)
    Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
  end

  get '/services/:id/destroy' do
    @service = Service.find(params[:id]) || not_found
    service_admins_only!
    @service.destroy!
    flash[:notice] = 'The service was deleted.'
    redirect "/o/#{@service.organisation.slug}/services"
  end

  get '/services/:id/bookings/:booking_id/destroy' do
    @service = Service.find(params[:id]) || not_found
    service_admins_only!
    @service.bookings.find(params[:booking_id]).try(:destroy)
    redirect back
  end
end
