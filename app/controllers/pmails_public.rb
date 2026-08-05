Dandelion::App.controller do
  get '/pmails/:pmail_id' do
    pass if params[:pmail_id] == 'new'
    @pmail = Pmail.find(params[:pmail_id]) || not_found
    headers['Content-Security-Policy'] = "default-src 'none'; img-src 'self' https: http: data:; style-src 'unsafe-inline'; script-src 'none'; object-src 'none'; base-uri 'none'"
    @pmail.html(viewing_on_web: true)
          .gsub('%recipient.firstname%', 'there')
          .gsub('%recipient.view_or_activate%', 'View your profile')
          .gsub(/%recipient\.\w+%/, '_')
  end

  post '/o/:slug/mailgun_webhook' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    body = request.body.read
    begin
      event = JSON.parse(body)
    rescue StandardError
      halt 406
    end

    halt 401 unless @organisation.mailgun_webhook_authentic?(event['signature'])

    if (pmail_id = event['event-data']['tags'].try(:first)) && (url = event['event-data']['url'])
      pmail = @organisation.pmails.find(pmail_id) || not_found
      uri = begin; URI(url); rescue StandardError; halt 406; end
      halt 406 unless uri.is_a?(URI::HTTP) && uri.host.present?

      uri_params = Rack::Utils.parse_nested_query(uri.query)
      uri_params.delete('sign_in_token')
      uri.query = uri_params.to_query
      url = uri.to_s
      url = url[0..-2] if uri_params.empty?

      pmail_link = pmail.pmail_links.find_or_create_by(url: url)
      if pmail_link.persisted?
        device_type = event.dig('event-data', 'client-info', 'device-type')
        pmail_link.record_click!(device_type: device_type)
      end
      halt 200
    else
      halt 406
    end
  end
end
