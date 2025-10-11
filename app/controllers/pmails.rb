Dandelion::App.controller do
  before do
    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id]) || not_found
      @_organisation = @organisation
      @scope = "organisation_id=#{@organisation.id}"
      organisation_admins_only!
      @pmails = @organisation.pmails
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id]) || not_found
      @_organisation = @activity.organisation
      @scope = "activity_id=#{@activity.id}"
      activity_admins_only!
      @pmails = @activity.pmails_including_events
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @_organisation = @local_group.organisation
      @scope = "local_group_id=#{@local_group.id}"
      local_group_admins_only!
      @pmails = @local_group.pmails_including_events
    elsif params[:event_id]
      @event = Event.find(params[:event_id]) || not_found
      @_organisation = @event.organisation
      @scope = "event_id=#{@event.id}"
      event_admins_only!
      @pmails = @event.pmails_as_mailable
    else
      kick!
    end
  end

  get '/pmails/new' do
    @pmail = Pmail.new
    @pmail.from = @organisation ? (@organisation.reply_to || "#{@organisation.name} <#{current_account.email}>") : "#{current_account.name} <#{current_account.email}>"
    @pmail.markdown = params[:markdown] ? true : false
    @pmail.body = %(Hi %recipient.firstname%,)
    erb :'pmails/build'
  end

  post '/pmails/new' do
    @pmail = Pmail.new(mass_assigning(params[:pmail], Pmail))
    @pmail.account = current_account
    if @organisation
      @pmail.organisation = @organisation
    elsif @activity
      @pmail.organisation = @activity.organisation
    elsif @local_group
      @pmail.organisation = @local_group.organisation
    elsif @event
      @pmail.organisation = @event.organisation
    end
    if @pmail.save
      flash[:notice] = 'The mail was saved. Preview and send using the buttons below.'
      redirect "/pmails/#{@pmail.id}/edit?#{@scope}"
    else
      erb :'pmails/build'
    end
  end

  get '/pmails/:pmail_id/edit' do
    @pmail = @pmails.find(params[:pmail_id]) || not_found
    erb :'pmails/build'
  end

  post '/pmails/:pmail_id/edit' do
    @pmail = @pmails.find(params[:pmail_id]) || not_found

    if params[:duplicate]
      @pmail.to_option = params[:pmail][:to_option]
      duplicated_pmail = @pmail.duplicate!(current_account)
      flash[:notice] = 'The mail was duplicated.'
      redirect "/pmails/#{duplicated_pmail.id}/edit?#{@scope}"
    end

    if @pmail.update_attributes(mass_assigning(params[:pmail], Pmail))
      flash[:notice] = 'The mail was saved. Preview and send using the buttons below.'
      if params[:send_test]
        @pmail.send_batch_message(test_to: Account.and(id: current_account.id))
        flash[:notice] = 'Test sent.'
        redirect "/pmails/#{@pmail.id}/edit?#{@scope}"
      elsif params[:send] || params[:send_later]
        @pmail.delayed_jobs.destroy_all
        if params[:send] && !@pmail.requested_send_at
          @pmail.update_attribute(:will_send_at, nil)
          @pmail.update_attribute(:requested_send_at, Time.now)
          @pmail.delay.send_pmail
          flash[:notice] = 'Sent!'
        elsif params[:send_later] && @pmail.will_send_at
          @pmail.delay(run_at: @pmail.will_send_at).send_pmail
          flash[:notice] = 'Scheduled!'
        end
        if @organisation
          redirect "/o/#{@organisation.slug}/pmails"
        elsif @activity
          redirect "/activities/#{@activity.id}/pmails"
        elsif @local_group
          redirect "/local_groups/#{@local_group.id}/pmails"
        elsif @event
          redirect "/events/#{@event.id}/pmails"
        end
      elsif params[:preview]
        redirect "/pmails/#{@pmail.id}/edit?#{@scope}&preview=1"
      elsif params[:file_q]
        redirect "/pmails/#{@pmail.id}/edit?#{@scope}&file_q=#{params[:file_q]}#attachments"
      else
        redirect "/pmails/#{@pmail.id}/edit?#{@scope}"
      end
    else
      erb :'pmails/build'
    end
  end

  get '/pmails/:pmail_id/preview' do
    @pmail = @pmails.find(params[:pmail_id]) || not_found
    @pmail.html.gsub('%recipient.firstname%', 'there').gsub('%recipient.footer_class%', 'd-none')
  end

  get '/pmails/:pmail_id/destroy' do
    @pmail = @pmails.find(params[:pmail_id]) || not_found
    halt 403 if @pmail.sent_at
    @pmail.destroy
    if @organisation
      redirect "/o/#{@organisation.slug}/pmails"
    elsif @activity
      redirect "/activities/#{@activity.id}/pmails"
    elsif @local_group
      redirect "/local_groups/#{@local_group.id}/pmails"
    elsif @event
      redirect "/events/#{@event.id}/pmails"
    end
  end

  get '/pmails/:oid/attachments' do
    @organisation = Organisation.find(params[:oid]) || not_found
    partial :'pmails/attachments'
  end

  get '/pmails/:oid/attachments/:attachment_id/destroy' do
    @organisation = Organisation.find(params[:oid]) || not_found
    @organisation.attachments.find(params[:attachment_id]).try(:destroy)
    200
  end
end
