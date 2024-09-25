module EventCallbacks
  extend ActiveSupport::Concern

  included do
    after_create do
      account.drafts.and(model: 'Event', name: name).destroy_all

      event_facilitations.create account: organisation.admins.first if organisation && organisation.admins.count == 1
      event_facilitations.create account: revenue_sharer if revenue_sharer

      activity.update_attribute(:hidden, false) if activity
      organisation.try(:update_paid_up)
    end

    after_save do
      if changes['name'] && (post = posts.find_by(subject: "Chat for #{changes['name'][0]}"))
        post.update_attribute(:subject, "Chat for #{name}")
      end

      if changes['activity_id']
        if activity && activity.privacy == 'open' && changes['activity_id'][0]
          previous_activity = Activity.find(changes['activity_id'][0])
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
        event_feedbacks.update_all(activity_id: activity_id)
      end

      if changes['local_group_id'] && local_group && changes['local_group_id'][0]
        previous_local_group = LocalGroup.find(changes['local_group_id'][0])
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
