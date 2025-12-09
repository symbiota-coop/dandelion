module EventCallbacks
  extend ActiveSupport::Concern

  included do
    after_create do
      account.drafts.and(model: 'Event', name: name).destroy_all

      event_facilitations.create account: organisation.admins.first if organisation && organisation.admins.count == 1
      event_facilitations.create account: revenue_sharer if revenue_sharer

      activity.set(locked: false) if activity
      organisation.try(:update_paid_up)
    end

    after_save do
      set_browsable
      set(event_tag_names: event_tags.map(&:name))

      if previous_changes['no_sales_after_end_time'] || previous_changes['end_time']
        set(sold_out_cache: sold_out?)
        set(sold_out_due_to_sales_end_cache: sold_out_due_to_sales_end?)
      end

      if previous_changes['name'] && (post = posts.find_by(subject: "Chat for #{previous_changes['name'][0]}"))
        post.set(subject: "Chat for #{name}")
      end

      if previous_changes['activity_id'] && activity && activity.privacy == 'open' && previous_changes['activity_id'][0]
        previous_activity = Activity.find(previous_changes['activity_id'][0])
        attendees.each do |account|
          next unless (previous_activityship = previous_activity.activityships.find_by(account: account))

          activity.activityships.create(
            account: account,
            unsubscribed: previous_activityship.unsubscribed,
            hide_membership: previous_activityship.hide_membership,
            receive_feedback: previous_activityship.receive_feedback
          )
        end
      end

      if previous_changes['local_group_id'] && local_group && previous_changes['local_group_id'][0]
        previous_local_group = LocalGroup.find(previous_changes['local_group_id'][0])
        attendees.each do |account|
          next unless (previous_local_groupship = previous_local_group.local_groupships.find_by(account: account))

          local_group.local_groupships.create(
            account: account,
            unsubscribed: previous_local_groupship.unsubscribed,
            hide_membership: previous_local_groupship.hide_membership,
            receive_feedback: previous_local_groupship.receive_feedback
          )
        end
      end

      if organisation && zoom_party
        organisation.local_groups.each do |local_group|
          zoomships.create local_group: local_group
        end
      end

      notifications.destroy_all if locked? || secret?

      account.send_first_event_email if !account.sent_first_event_email && account.events.count == 1 && created_at > 1.week.ago
    end

    after_destroy do
      organisation.try(:update_paid_up)
    end

    after_create do
      if circle && !prevent_notifications && live? && public?
        notifications.and(:type.in => %w[created_event updated_event]).destroy_all
        notifications.create! circle: circle, type: 'created_event'
      end
    end
    after_update do
      if circle && !prevent_notifications && live? && public?
        notifications.and(:type.in => %w[created_event updated_event]).destroy_all
        notifications.create! circle: circle, type: 'updated_event'
      end
    end
  end
end
