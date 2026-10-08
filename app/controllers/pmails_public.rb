Dandelion::App.controller do
  get '/pmails/:pmail_id' do
    pass if params[:pmail_id] == 'new'
    @pmail = Pmail.find_by_id_or_token(params[:pmail_id]) || not_found
    not_found unless @pmail.sent_at
    email_html_csp!
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
      uri = HttpUrl.parse(url) || halt(406)

      uri_params = Rack::Utils.parse_nested_query(uri.query)
      uri_params.delete('sign_in_token')
      uri.query = (uri_params.to_query if uri_params.any?)
      url = uri.to_s

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
