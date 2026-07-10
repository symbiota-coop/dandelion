class Post
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, inverse_of: :posts_as_creator
  belongs_to_without_parent_validation :commentable, polymorphic: true

  field :subject, type: String

  has_many :subscriptions, dependent: :destroy
  has_many :comments, dependent: :destroy
  has_many :comment_reactions, dependent: :destroy

  after_create do
    commentable.discussers.each { |account| subscriptions.create account: account }
  end

  def self.commentable_types
    %w[Team Tactivity Mapplication Event ActivityApplication]
    # Account Organisation LocalGroup Activity Gathering
  end

  # Mirrors parent-page authorization for private discussions.
  def self.viewer?(commentable, account, event_participant: nil, activity_admin: nil)
    return false unless commentable && account

    case commentable
    when Team, Tactivity, Mapplication
      gathering = commentable.gathering
      (membership = gathering.memberships.find_by(account: account)) && membership.confirmed?
    when Event
      !commentable.hide_discussion && (event_participant || (event_participant.nil? && Event.participant?(commentable, account)))
    when ActivityApplication
      activity_admin || (activity_admin.nil? && Activity.admin?(commentable.activity, account))
    else
      false
    end
  end

  def url
    case commentable
    when Team
      team = commentable
      "#{ENV['BASE_URI']}/g/#{team.gathering.slug}/teams/#{team.id}#post-#{id}"
    when Tactivity
      tactivity = commentable
      "#{ENV['BASE_URI']}/g/#{tactivity.gathering.slug}/tactivities/#{tactivity.id}#post-#{id}"
    when Mapplication
      mapplication = commentable
      "#{ENV['BASE_URI']}/g/#{mapplication.gathering.slug}/mapplications/#{mapplication.id}#post-#{id}"
    when Event
      event = commentable
      "#{ENV['BASE_URI']}/events/#{event.id}"
    when ActivityApplication
      activity_application = commentable
      "#{ENV['BASE_URI']}/activities/#{activity_application.activity_id}/activity_applications/#{activity_application.id}"
    end
  end

  def discussers
    # for comment.discussers
    Account.and(unsubscribed: false).and(:id.in => subscriptions.pluck(:account_id))
  end
end
