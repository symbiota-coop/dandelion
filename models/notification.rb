class Notification
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :circle, polymorphic: true
  belongs_to_without_parent_validation :notifiable, polymorphic: true

  field :type, type: String

  def self.circle_types
    %w[Account Gathering Activity LocalGroup Organisation]
  end

  def self.notifiable_types
    %w[Gathering Mapplication Membership Teamship Spend Account Tactivity Shift Attendance Team Option Rota Timetable Comment CommentReaction Payment InventoryItem Event Organisation Order EventFeedback]
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
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "[#{circle.name}] #{Nokogiri::HTML(notification.sentence).text}"
    batch_message.body_html EmailHelper.html(:notification, notification: notification, circle: circle)

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
      "#{strong_text(gathering.account.name)} created the gathering"
    when :applied
      mapplication = notifiable
      "#{strong_text(mapplication.account.name)} applied"
    when :joined_gathering
      membership = notifiable
      mapplication = membership.mapplication
      if mapplication
        if mapplication.processed_by
          "#{strong_text(membership.account.name)} was accepted by #{strong_text(mapplication.processed_by.name)}"
        else
          "#{strong_text(membership.account.name)} was accepted"
        end
      elsif membership.added_by
        "#{strong_text(membership.account.name)} was added by #{safe_text(membership.added_by.name)}"
      else
        "#{strong_text(membership.account.name)} joined the gathering"
      end
    when :joined_team
      teamship = notifiable
      "#{strong_text(teamship.account.name)} joined the #{strong_text(teamship.team.name)} team"
    when :created_spend
      spend = notifiable
      amount = Money.new(spend.amount * 100, spend.gathering.currency).format(no_cents_if_whole: true)
      "#{strong_text(spend.account.name)} spent #{safe_text(amount)} on #{strong_text(spend.item)}"
    when :created_profile
      account = notifiable
      "#{strong_text(account.name)} joined Dandelion!"
    when :updated_profile
      account = notifiable
      "#{strong_text(account.name)} updated #{safe_text(account.pronoun)} profile"
    when :created_tactivity
      tactivity = notifiable
      "#{strong_text(tactivity.account.name)} proposed the activity #{strong_text(tactivity.name)} under #{strong_text(tactivity.timetable.name)}"
    when :signed_up_to_a_shift
      shift = notifiable
      "#{strong_text(shift.account.name)} signed up for a #{strong_text(shift.rota.name)} shift"
    when :interested_in_tactivity
      attendance = notifiable
      "#{strong_text(attendance.account.name)} is interested in #{strong_text(attendance.tactivity.name)}"
    when :created_team
      team = notifiable
      "#{strong_text(team.account.name)} created the team #{strong_text(team.name)}"
    when :created_option
      option = notifiable
      "#{strong_text(option.account.name)} created the option #{strong_text(option.name)}"
    when :created_rota
      rota = notifiable
      "#{strong_text(rota.account.name)} created the rota #{strong_text(rota.name)}"
    when :scheduled_tactivity
      tactivity = notifiable
      if tactivity.scheduled_by
        "#{strong_text(tactivity.scheduled_by.name)} scheduled the activity #{strong_text(tactivity.name)}"
      else
        "The activity #{strong_text(tactivity.name)} was scheduled"
      end
    when :unscheduled_tactivity
      tactivity = notifiable
      if tactivity.scheduled_by
        "#{strong_text(tactivity.scheduled_by.name)} unscheduled the activity #{strong_text(tactivity.name)}"
      else
        "The activity #{strong_text(tactivity.name)} was unscheduled"
      end
    when :made_admin
      membership = notifiable
      "#{strong_text(membership.account.name)} was made an admin by #{strong_text(membership.admin_status_changed_by.name)}"
    when :unadmined
      membership = notifiable
      "#{strong_text(membership.account.name)} was unadmined by #{strong_text(membership.admin_status_changed_by.name)}"
    when :created_timetable
      timetable = notifiable
      "#{strong_text(timetable.account.name)} created the timetable #{strong_text(timetable.name)}"
    when :commented
      comment = notifiable
      if comment.commentable.is_a?(Mapplication)
        "#{strong_text(comment.account.name)} commented on #{strong_text(comment.commentable.account.name)}'s application"
      elsif comment.first_in_post?
        "#{strong_text(comment.account.name)} started a thread #{strong_text("#{comment.commentable.name}/#{comment.post.subject}")}"
      else
        "#{strong_text(comment.account.name)} replied to #{strong_text("#{comment.commentable.name}/#{comment.post.subject}")}"
      end
    when :reacted_to_a_comment
      comment_reaction = notifiable
      reaction = comment_reaction.body == '💚' ? '<i class="text-primary bi bi-heart-fill"></i>' : safe_text(comment_reaction.body)
      "#{strong_text(comment_reaction.account.name)} reacted with #{reaction} to #{strong_text("#{comment_reaction.comment.account.name}'s")} comment in #{strong_text("#{comment_reaction.commentable.name}/#{comment_reaction.comment.post.subject}")}"
    when :left_gathering
      account = notifiable
      "#{strong_text(account.name)} is no longer a member"
    when :created_payment
      payment = notifiable
      amount = Money.new(payment.amount * 100, payment.currency).format(no_cents_if_whole: true)
      "#{strong_text(payment.account.name)} made a payment of #{safe_text(amount)}"
    when :created_inventory_item
      inventory_item = notifiable
      if inventory_item.account
        "#{strong_text(inventory_item.account.name)} listed the item #{strong_text(inventory_item.name)}"
      else
        "Someone listed the item #{strong_text(inventory_item.name)}"
      end
    when :mapplication_removed
      account = notifiable
      "#{strong_text(account.name)}'s application was deleted"
    when :created_event, :updated_event
      event = notifiable
      verb = type.to_sym == :created_event ? 'created' : 'updated'
      when_suffix = event.evergreen? ? nil : event.concise_when_details(nil)
      sentence = "#{strong_text(event.organisation.name)} #{verb} the event #{strong_text(event.name)}"
      sentence = "#{sentence}, #{safe_text(when_suffix)}" if when_suffix
      sentence
    when :created_organisation
      organisation = notifiable
      if organisation.account
        "#{strong_text(organisation.account.name)} created the organisation #{strong_text(organisation.name)}"
      else
        "A new organisation #{strong_text(organisation.name)} was created"
      end
    when :created_order
      order = notifiable
      "#{strong_text(order.account.name)} is going to #{strong_text(order.event.name)}"
    when :left_feedback
      event_feedback = notifiable
      if event_feedback.event
        "#{strong_text(event_feedback.account.name)} left feedback on #{strong_text(event_feedback.event.name)}"
      else
        "#{strong_text(event_feedback.account.name)} left feedback on an event"
      end
    when :starred_event
      account = circle
      event = notifiable
      "#{strong_text(account.name)} starred the event #{strong_text(event.name)}"
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
      ['View event', "#{ENV['BASE_URI']}/e/#{notifiable.slug}"]
    when :updated_event
      ['View event', "#{ENV['BASE_URI']}/e/#{notifiable.slug}"]
    when :created_organisation
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
      'bi-key-fill'
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

  private

  def safe_text(text)
    ERB::Util.html_escape(text.to_s)
  end

  def strong_text(text)
    "<strong>#{ERB::Util.html_escape(text.to_s)}</strong>"
  end
end
