Dandelion::App.controller do
  get '/o/:slug/feedback' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @event_feedbacks = @organisation.event_feedbacks
    erb :'organisations/event_feedbacks'
  end

  get '/activities/:id/feedback' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @event_feedbacks = @activity.event_feedbacks
    erb :'activities/event_feedbacks'
  end

  get '/local_groups/:id/feedback' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @event_feedbacks = @local_group.event_feedbacks
    erb :'local_groups/event_feedbacks'
  end

  get '/events/:id/feedback' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event_feedbacks = @event.event_feedbacks
    erb :'events/event_feedbacks'
  end

  get '/event_feedbacks/:id' do
    @event_feedback = EventFeedback.find(params[:id]) || not_found
    @event = @event_feedback.event
    event_admins_only!
    erb :'event_feedbacks/event_feedback'
  end

  get '/event_feedbacks/:id/destroy' do
    @event_feedback = EventFeedback.find(params[:id]) || not_found
    @event = @event_feedback.event
    @organisation = @event.organisation
    organisation_admins_only!
    @event_feedback.send_destroy_notification(current_account)
    @event_feedback.destroy
    redirect back
  end

  get '/events/:id/give_feedback' do
    @event = Event.find(params[:id]) || not_found
    @account = if admin? && params[:email]
                 Account.find_by(email: params[:email].downcase)
               elsif params[:t]
                 Account.find(params[:t])
               else
                 current_account
               end
    kick! unless @account
    unless @account && @event.attendees.include?(@account)
      flash[:error] = "You didn't attend that event!"
      redirect "/o/#{@event.organisation.slug}/events"
    end
    if @event.event_feedbacks.find_by(account: @account)
      flash[:error] = "You've already left feedback on that event"
      redirect "/o/#{@event.organisation.slug}/events"
    end
    @title = "Feedback on #{@event.name}#{" for #{@account.name}" if params[:email]}"
    @event_feedback = @event.event_feedbacks.build(account: @account)
    erb :'event_feedbacks/build'
  end

  post '/events/:id/give_feedback' do
    @event = Event.find(params[:id]) || not_found
    @title = "Feedback on #{@event.name}"
    @event_feedback = @event.event_feedbacks.new(mass_assigning(params[:event_feedback], EventFeedback))
    @event_feedback.public = params[:public]
    @event_feedback.anonymise = params[:anonymise]
    @event_feedback.answers = (params[:answers].map { |i, x| [@event.feedback_questions_a[i.to_i], x] } if params[:answers])
    @event_feedback.save
    flash[:notice] = 'Thanks for your feedback!'
    redirect "/donate?account_id=#{@event_feedback.account_id}"
    # if @event.organisation.events_for_search.future_and_current_featured.count > 0
    #   redirect "/o/#{@event.organisation.slug}/events?gave_feedback=1"
    # else
    #   redirect '/events'
    # end
  end

  get '/event_feedbacks/:id/public/:i' do
    @event_feedback = EventFeedback.find(params[:id]) || not_found
    @event = @event_feedback.event
    event_admins_only!
    partial :'event_feedbacks/public'
  end

  post '/event_feedbacks/:id/public/:i' do
    @event_feedback = EventFeedback.find(params[:id]) || not_found
    @event = @event_feedback.event
    event_admins_only!

    public_answers = @event_feedback.event.feedback_questions_a.map { |q| [q, ''] }

    # keep existing answers
    if @event_feedback.public_answers
      public_answers.each_with_index do |qa, i|
        q = qa[0]
        if (existing_qa = @event_feedback.public_answers.detect { |k, _v| k == q })
          public_answers[i][1] = existing_qa[1]
        end
      end
    end

    # set new answer
    public_answers[params[:i].to_i][1] = params[:public]

    @event_feedback.public_answers = public_answers.all? { |_k, v| v.blank? } ? nil : public_answers
    @event_feedback.save
    200
  end
end
