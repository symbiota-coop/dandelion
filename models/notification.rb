class Notification
  include Mongoid::Document
  include Mongoid::Timestamps
  include DandelionMongo

  belongs_to_without_parent_validation :circle, polymorphic: true, index: true
  belongs_to_without_parent_validation :notifiable, polymorphic: true, index: true

  field :type, type: String

  def self.admin_fields
    {
      circle_type: :text,
      circle_id: :text,
      notifiable_type: :text,
      notifiable_id: :text,
      type: :text
    }
  end

  def self.circle_types
    %w[Account Gathering Activity LocalGroup Organisation]
  end

  def circle_url
    case circle
    when Gathering
      "#{ENV['BASE_URI']}/g/#{circle.slug}"
    when Account
      "#{ENV['BASE_URI']}/accounts/#{circle.id}"
    when Activity
      "#{ENV['BASE_URI']}/activities/#{circle.id}"
    when LocalGroup
      "#{ENV['BASE_URI']}/local_groups/#{circle.id}"
    when Organisation
      "#{ENV['BASE_URI']}/o/#{circle.slug}"
    end
  end

  validates_presence_of :type

  before_validation do
    errors.add(:type, 'not found') unless Notification.types.include?(type)
  end

  def self.types
    %w[created_gathering applied joined_gathering created_team created_timetable created_tactivity created_rota created_option created_spend created_profile updated_profile joined_team signed_up_to_a_shift interested_in_tactivity scheduled_tactivity unscheduled_tactivity made_admin unadmined commented reacted_to_a_comment left_gathering created_payment created_inventory_item mapplication_removed created_event updated_event created_organisation created_order left_feedback starred_event]
  end

  def self.mailable_types
    %w[created_gathering created_team created_timetable created_rota created_spend]
  end

  after_create :send_email
  def send_email
    return unless Notification.mailable_types.include?(type)

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    notification = self
    circle = self.circle
    content = ERB.new(File.read(Padrino.root('app/views/emails/notification.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "[#{circle.name}] #{Nokogiri::HTML(notification.sentence).text}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    circle.discussers.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
  handle_asynchronously :send_email

  def sentence
    case type.to_sym
    when :created_gathering
      gathering = notifiable
      "<strong>#{gathering.account.name}</strong> created the gathering"
    when :applied
      mapplication = notifiable
      "<strong>#{mapplication.account.name}</strong> applied"
    when :joined_gathering
      membership = notifiable
      mapplication = membership.mapplication
      if mapplication
        if mapplication.processed_by
          "<strong>#{membership.account.name}</strong> was accepted by <strong>#{mapplication.processed_by.name}</strong>"
        else
          "<strong>#{membership.account.name}</strong> was accepted"
        end
      elsif membership.added_by
        "<strong>#{membership.account.name}</strong> was added by #{membership.added_by.name}"
      else
        "<strong>#{membership.account.name}</strong> joined the gathering"
      end
    when :joined_team
      teamship = notifiable
      "<strong>#{teamship.account.name}</strong> joined the <strong>#{teamship.team.name}</strong> team"
    when :created_spend
      spend = notifiable
      "<strong>#{spend.account.name}</strong> spent #{Money.new(spend.amount * 100, spend.gathering.currency).format(no_cents_if_whole: true)} on <strong>#{spend.item}</strong>"
    when :created_profile
      account = notifiable
      "<strong>#{account.name}</strong> joined Dandelion!"
    when :updated_profile
      account = notifiable
      "<strong>#{account.name}</strong> updated #{account.pronoun} profile"
    when :created_tactivity
      tactivity = notifiable
      "<strong>#{tactivity.account.name}</strong> proposed the activity <strong>#{tactivity.name}</strong> under <strong>#{tactivity.timetable.name}</strong>"
    when :signed_up_to_a_shift
      shift = notifiable
      "<strong>#{shift.account.name}</strong> signed up for a <strong>#{shift.rota.name}</strong> shift"
    when :interested_in_tactivity
      attendance = notifiable
      "<strong>#{attendance.account.name}</strong> is interested in <strong>#{attendance.tactivity.name}</strong>"
    when :created_team
      team = notifiable
      "<strong>#{team.account.name}</strong> created the team <strong>#{team.name}</strong>"
    when :created_option
      option = notifiable
      "<strong>#{option.account.name}</strong> created the option <strong>#{option.name}</strong>"
    when :created_rota
      rota = notifiable
      "<strong>#{rota.account.name}</strong> created the rota <strong>#{rota.name}</strong>"
    when :scheduled_tactivity
      tactivity = notifiable
      if tactivity.scheduled_by
        "<strong>#{tactivity.scheduled_by.name}</strong> scheduled the activity <strong>#{tactivity.name}</strong>"
      else
        "The activity <strong>#{tactivity.name}</strong> was scheduled"
      end
    when :unscheduled_tactivity
      tactivity = notifiable
      if tactivity.scheduled_by
        "<strong>#{tactivity.scheduled_by.name}</strong> unscheduled the activity <strong>#{tactivity.name}</strong>"
      else
        "The activity <strong>#{tactivity.name}</strong> was unscheduled"
      end
    when :made_admin
      membership = notifiable
      "<strong>#{membership.account.name}</strong> was made an admin by <strong>#{membership.admin_status_changed_by.name}</strong>"
    when :unadmined
      membership = notifiable
      "<strong>#{membership.account.name}</strong> was unadmined by <strong>#{membership.admin_status_changed_by.name}</strong>"
    when :created_timetable
      timetable = notifiable
      "<strong>#{timetable.account.name}</strong> created the timetable <strong>#{timetable.name}</strong>"
    when :commented
      comment = notifiable
      if comment.commentable.is_a?(Mapplication)
        "<strong>#{comment.account.name}</strong> commented on <strong>#{comment.commentable.account.name}</strong>'s application"
      elsif comment.first_in_post?
        "<strong>#{comment.account.name}</strong> started a thread <strong>#{comment.commentable.name}/#{comment.post.subject}</strong>"
      else
        "<strong>#{comment.account.name}</strong> replied to <strong>#{comment.commentable.name}/#{comment.post.subject}</strong>"
      end
    when :reacted_to_a_comment
      comment_reaction = notifiable
      "<strong>#{comment_reaction.account.name}</strong> reacted with #{comment_reaction.body == '💚' ? '<i class="text-primary bi bi-heart-fill"></i>' : comment_reaction.body} to <strong>#{comment_reaction.comment.account.name}'s</strong> comment in <strong>#{comment_reaction.commentable.name}/#{comment_reaction.comment.post.subject}</strong>"
    when :left_gathering
      account = notifiable
      "<strong>#{account.name}</strong> is no longer a member"
    when :created_payment
      payment = notifiable
      "<strong>#{payment.account.name}</strong> made a payment of #{Money.new(payment.amount * 100, payment.currency).format(no_cents_if_whole: true)}"
    when :created_inventory_item
      inventory_item = notifiable
      if inventory_item.account
        "<strong>#{inventory_item.account.name}</strong> listed the item <strong>#{inventory_item.name}</strong>"
      else
        "Someone listed the item <strong>#{inventory_item.name}</strong>"
      end
    when :mapplication_removed
      account = notifiable
      "<strong>#{account.name}</strong>'s application was deleted"
    when :created_event
      event = notifiable
      "<strong>#{event.organisation.name}</strong> created the event <strong>#{event.name}</strong>, #{event.concise_when_details(nil)}"
    when :updated_event
      event = notifiable
      "<strong>#{event.organisation.name}</strong> updated the event <strong>#{event.name}</strong>, #{event.concise_when_details(nil)}"
    when :created_organisation
      organisation = notifiable
      if organisation.account
        "<strong>#{organisation.account.name}</strong> created the organisation <strong>#{organisation.name}</strong>"
      else
        "A new organisation <strong>#{organisation.name}</strong> was created"
      end
    when :created_order
      order = notifiable
      "<strong>#{order.account.name}</strong> is going to <strong>#{order.event.name}</strong>"
    when :left_feedback
      event_feedback = notifiable
      "<strong>#{event_feedback.account.name}</strong> left feedback on <strong>#{event_feedback.event.name}</strong>"
    when :starred_event
      account = circle
      event = notifiable
      "<strong>#{account.name}</strong> starred the event <strong>#{event.name}</strong>"
    end.html_safe
  end

  def link
    case type.to_sym
    when :created_gathering
      ['View gathering', "#{ENV['BASE_URI']}/g/#{circle.slug}"]
    when :applied
      ['View applications', "#{ENV['BASE_URI']}/g/#{circle.slug}/applications"]
    when :joined_gathering
      ['View members', "#{ENV['BASE_URI']}/g/#{circle.slug}/members"]
    when :joined_team
      ['View team', "#{ENV['BASE_URI']}/g/#{circle.slug}/teams/#{notifiable.team_id}"]
    when :created_spend
      ['View budget', "#{ENV['BASE_URI']}/g/#{circle.slug}/budget"]
    when :created_profile
      ['View profile', "#{ENV['BASE_URI']}/u/#{notifiable.username}"]
    when :updated_profile
      ['View profile', "#{ENV['BASE_URI']}/u/#{notifiable.username}"]
    when :created_tactivity
      ['View activity', "#{ENV['BASE_URI']}/g/#{circle.slug}/tactivities/#{notifiable.id}"]
    when :signed_up_to_a_shift
      ['View rotas', "#{ENV['BASE_URI']}/g/#{circle.slug}/rotas"]
    when :interested_in_tactivity
      ['View activity', "#{ENV['BASE_URI']}/g/#{circle.slug}/tactivities/#{notifiable.tactivity_id}"]
    when :created_team
      ['View team', "#{ENV['BASE_URI']}/g/#{circle.slug}/teams/#{notifiable.id}"]
    when :created_option
      ['View options', "#{ENV['BASE_URI']}/g/#{circle.slug}/options"]
    when :created_rota
      ['View rotas', "#{ENV['BASE_URI']}/g/#{circle.slug}/rotas/#{notifiable.id}"]
    when :scheduled_tactivity
      ['View activity', "#{ENV['BASE_URI']}/g/#{circle.slug}/tactivities/#{notifiable.id}"]
    when :unscheduled_tactivity
      ['View activity', "#{ENV['BASE_URI']}/g/#{circle.slug}/tactivities/#{notifiable.id}"]
    when :made_admin
      ['View members', "#{ENV['BASE_URI']}/g/#{circle.slug}/members"]
    when :unadmined
      ['View members', "#{ENV['BASE_URI']}/g/#{circle.slug}/members"]
    when :created_timetable
      ['View timetable', "#{ENV['BASE_URI']}/g/#{circle.slug}/timetables/#{notifiable.id}"]
    when :commented
      ['View post', notifiable.post.url]
    when :reacted_to_a_comment
      ['View post', notifiable.post.url]
    when :left_gathering
      ['View members', "#{ENV['BASE_URI']}/g/#{circle.slug}/members"]
    when :created_payment
      ['View budget', "#{ENV['BASE_URI']}/g/#{circle.slug}/budget"]
    when :created_inventory_item
      ['View inventory', "#{ENV['BASE_URI']}/g/#{circle.slug}/inventory"]
    when :mapplication_removed
      ['View applications', "#{ENV['BASE_URI']}/g/#{circle.slug}/applications"]
    when :created_event
      return nil unless notifiable&.slug
      ['View event', "#{ENV['BASE_URI']}/e/#{notifiable.slug}"]
    when :updated_event
      return nil unless notifiable&.slug
      ['View event', "#{ENV['BASE_URI']}/e/#{notifiable.slug}"]
    when :created_organisation
      return nil unless notifiable&.slug
      ['View organisation', "#{ENV['BASE_URI']}/o/#{notifiable.slug}"]
    when :created_order
      ['View event', "#{ENV['BASE_URI']}/events/#{notifiable.event_id}"]
    when :left_feedback
      ['View event', "#{ENV['BASE_URI']}/events/#{notifiable.event_id}"]
    when :starred_event
      ['View event', "#{ENV['BASE_URI']}/events/#{notifiable.id}"]
    end
  end

  def icon
    case type.to_sym
    when :created_gathering
      'bi-people-fill'
    when :applied
      'bi-file-text'
    when :joined_gathering
      'bi-person-fill-add'
    when :joined_team
      'bi-people-fill'
    when :created_spend
      'bi-cash-coin'
    when :created_profile
      'bi-person-fill'
    when :updated_profile
      'bi-person-fill'
    when :created_tactivity
      'bi-easel'
    when :signed_up_to_a_shift
      'bi-hand-index'
    when :interested_in_tactivity
      'bi-hand-thumbs-up'
    when :created_team
      'bi-people-fill'
    when :created_option
      'bi-check-lg'
    when :created_rota
      'bi-table'
    when :scheduled_tactivity
      'bi-calendar-plus'
    when :unscheduled_tactivity
      'bi-calendar-minus'
    when :made_admin
      'bi-key'
    when :unadmined
      'bi-key'
    when :created_timetable
      'bi-table'
    when :commented
      'bi-chat-left-text'
    when :reacted_to_a_comment
      'bi-hand-thumbs-up'
    when :left_gathering
      'bi-box-arrow-right'
    when :created_payment
      'bi-cash-coin'
    when :created_inventory_item
      'bi-wrench'
    when :mapplication_removed
      'bi-file-text'
    when :created_event
      'bi-calendar-plus'
    when :updated_event
      'bi-calendar-event'
    when :created_organisation
      'bi-flag-fill'
    when :created_order
      'bi-ticket-detailed-fill'
    when :left_feedback
      'bi-chat-left-quote'
    when :starred_event
      'bi-star'
    end
  end
end
