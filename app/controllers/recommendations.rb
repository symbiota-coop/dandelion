Dandelion::App.controller do
  before do
    sign_in_required!
    @account = current_account
    events = Event.where(:id.in => @account.tickets.pluck(:event_id) + @account.event_facilitations.pluck(:event_id))
    @friends = {}
    events.each do |event|
      (event.attendees + event.event_facilitators).each do |attendee|
        next if attendee.id == @account.id

        if !@friends[attendee.id]
          @friends[attendee.id] = [event.id]
        else
          @friends[attendee.id] << event.id
        end
      end
    end
    @friends = @friends.sort_by { |_k, v| -v.count }
  end

  get '/recommendations/accounts' do
    erb :'recommendations/accounts'
  end

  get '/recommendations/events' do
    erb :'recommendations/events'
  end
end
