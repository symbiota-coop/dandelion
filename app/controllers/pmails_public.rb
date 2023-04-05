Dandelion::App.controller do
  get '/pmails/:pmail_id' do
    pass if params[:pmail_id] == 'new'
    @pmail = Pmail.find(params[:pmail_id]) || not_found
    @pmail.html(share_buttons: true)
          .gsub('%recipient.firstname%', 'there')
          .gsub('%recipient.view_or_activate%', 'View your profile')
          .gsub(/%recipient\.\w+%/, '_')
          .gsub('%share_buttons%', partial(:share, locals: {
                                             share_url: "#{ENV['BASE_URI']}/pmails/#{@pmail.id}",
                                             div_style: 'display: flex; justify-content: center;'
                                           }))
  end

  post '/o/:slug/mailgun_webhook' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    begin
      event = JSON.parse(request.body.read)
    rescue StandardError
      halt 406
    end
    if (pmail_id = event['event-data']['tags'].try(:first)) && (url = event['event-data']['url'])
      pmail = @organisation.pmails.find(pmail_id) || not_found
      uri = begin; URI(url); rescue StandardError; halt 406; end
      uri_params = Rack::Utils.parse_nested_query(uri.query)
      uri_params.delete('sign_in_token')
      uri.query = uri_params.to_query
      url = uri.to_s
      url = url[0..-2] if uri_params.empty?

      pmail_link = pmail.pmail_links.find_or_create_by(url: url)
      pmail_link.update_attribute(:clicks, (pmail_link.clicks || 0) + 1) if pmail_link.persisted?
      halt 200
    else
      halt 406
    end
  end
end
