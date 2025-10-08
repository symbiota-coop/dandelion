Dandelion::App.controller do
  get '/facilitators' do
    f = Fragment.find_by(key: 'facilitator_feedback_counts')
    @account_ids_freq = JSON.parse(f.value)
    @account_ids_freq = @account_ids_freq.paginate(page: params[:page], per_page: 10)
    @accounts = Account.and(:id.in => @account_ids_freq.map { |id, _freq| id })
    erb :'facilitators/facilitators'
  end

  get '/facilitators/map', provides: %i[html json] do
    @no_content_padding_bottom = true
    f = Fragment.find_by(key: 'facilitator_feedback_counts')
    account_ids_freq = JSON.parse(f.value)

    # Get public accounts from all IDs
    public_account_ids = Account.and(:location_privacy => 'Public', :id.in => account_ids_freq.map { |id, _freq| id }).pluck(:id).map(&:to_s)

    # Filter to only public accounts and keep the sorting by count, then take top 500
    public_account_ids_freq = account_ids_freq.select { |id, _freq| public_account_ids.include?(id) }.take(500)

    @accounts = Account.and(:id.in => public_account_ids_freq.map { |id, _freq| id })
    case content_type
    when :html
      erb :'facilitators/map'
    when :json
      map_json(@accounts)
    end
  end
end
