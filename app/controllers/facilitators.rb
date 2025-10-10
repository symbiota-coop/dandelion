Dandelion::App.controller do
  get '/facilitators', provides: %i[html json] do
    @accounts = Account.and(:event_feedbacks_as_facilitator_count.gt => 0).order('event_feedbacks_as_facilitator_count desc')
    if params[:q]
      ids_from_search = Account.search(params[:q], @accounts).pluck(:id)
      ids_from_tags = @accounts.and(event_tag_names: /#{Regexp.escape(params[:q])}/i).pluck(:id)
      @accounts = @accounts.and(:id.in => ids_from_search + ids_from_tags)
    end
    @accounts = @accounts.and(coordinates: { '$geoWithin' => { '$box' => @bounding_box } }) if params[:near] && %w[north south east west].all? { |p| params[p].nil? } && (@bounding_box = calculate_geographic_bounding_box(params[:near]))

    case content_type
    when :html
      @accounts = @accounts.paginate(page: params[:page], per_page: 10)
      erb :'facilitators/facilitators'
    when :json
      @no_content_padding_bottom = true
      @accounts = Account.and(:id.in => @accounts.and(location_privacy: 'Public').limit(500).pluck(:id))
      map_json(@accounts)
    end
  end
end
