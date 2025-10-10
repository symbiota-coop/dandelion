Dandelion::App.controller do
  get '/facilitators', provides: %i[html json] do
    f = Fragment.find_by(key: 'facilitator_feedback_counts')
    @account_ids_freq = JSON.parse(f.value)
    @accounts = Account.and(:id.in => @account_ids_freq.map { |id, _freq| id })

    if params[:q]
      # Search by account fields
      account_ids_from_search = Account.search(params[:q], @accounts).pluck(:id)

      # Search by event tags of past events
      matching_tag_ids = EventTag.where(name: /#{Regexp.escape(params[:q])}/i).pluck(:id)
      if matching_tag_ids.any?
        # Use aggregation to efficiently find accounts who facilitated past events with matching tags
        account_ids_from_tags = EventFacilitation.collection.aggregate([
                                                                         # Join with events to filter by past events
                                                                         {
                                                                           '$lookup' => {
                                                                             'from' => 'events',
                                                                             'localField' => 'event_id',
                                                                             'foreignField' => '_id',
                                                                             'as' => 'event'
                                                                           }
                                                                         },
                                                                         { '$unwind' => '$event' },
                                                                         # Filter to past events only
                                                                         { '$match' => { 'event.start_time' => { '$lt' => Date.today } } },
                                                                         # Join with event tagships
                                                                         {
                                                                           '$lookup' => {
                                                                             'from' => 'event_tagships',
                                                                             'localField' => 'event_id',
                                                                             'foreignField' => 'event_id',
                                                                             'as' => 'tagships'
                                                                           }
                                                                         },
                                                                         { '$unwind' => '$tagships' },
                                                                         # Filter to matching tags
                                                                         { '$match' => { 'tagships.event_tag_id' => { '$in' => matching_tag_ids } } },
                                                                         # Group by account_id to get unique accounts
                                                                         { '$group' => { '_id' => '$account_id' } }
                                                                       ]).map { |doc| doc['_id'] }

        # Combine both sets of account IDs
        combined_account_ids = (account_ids_from_search + account_ids_from_tags).uniq
        @accounts = @accounts.and(:id.in => combined_account_ids)
      else
        @accounts = @accounts.and(:id.in => account_ids_from_search)
      end
    end

    # Geographic filtering (common to both html and json)
    @accounts = @accounts.and(coordinates: { '$geoWithin' => { '$box' => @bounding_box } }) if params[:near] && %w[north south east west].all? { |p| params[p].nil? } && (@bounding_box = calculate_geographic_bounding_box(params[:near]))

    case content_type
    when :html
      @account_ids_freq = @account_ids_freq.paginate(page: params[:page], per_page: 10)
      erb :'facilitators/facilitators'
    when :json
      @no_content_padding_bottom = true
      # Get public accounts from already filtered @accounts
      public_account_ids = @accounts.and(location_privacy: 'Public').pluck(:id).map(&:to_s)
      # Filter to only public accounts and keep the sorting by count, then take top 500
      public_account_ids_freq = @account_ids_freq.select { |id, _freq| public_account_ids.include?(id) }.take(500)
      @accounts = Account.and(:id.in => public_account_ids_freq.map { |id, _freq| id })
      map_json(@accounts)
    end
  end
end
