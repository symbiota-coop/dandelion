class Post
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :account, index: true, inverse_of: :posts_as_creator
  belongs_to :commentable, polymorphic: true, index: true

  field :subject, type: String

  def self.admin_fields
    {
      id: { type: :text, edit: false },
      subject: :text,
      account_id: :lookup,
      commentable_id: :text,
      commentable_type: :select,
      subscriptions: :collection,
      comments: :collection
    }
  end

  has_many :subscriptions, dependent: :destroy
  has_many :comments, dependent: :destroy
  has_many :comment_reactions, dependent: :destroy

  after_create do
    commentable.discussers.each { |account| subscriptions.create account: account }
  end

  def self.commentable_types
    %w[DocPage Team Tactivity Mapplication Account Place Gathering Activity Event LocalGroup Organisation ActivityApplication]
  end

  def url
    case commentable
    when DocPage
      doc_page = commentable
      "#{ENV['BASE_URI']}/docs/#{doc_page.slug}#post-#{id}"
    when Team
      team = commentable
      "#{ENV['BASE_URI']}/g/#{team.gathering.slug}/teams/#{team.id}#post-#{id}"
    when Gathering
      gathering = commentable
      "#{ENV['BASE_URI']}/g/#{gathering.slug}"
    when Tactivity
      tactivity = commentable
      "#{ENV['BASE_URI']}/g/#{tactivity.gathering.slug}/tactivities/#{tactivity.id}#post-#{id}"
    when Mapplication
      mapplication = commentable
      "#{ENV['BASE_URI']}/g/#{mapplication.gathering.slug}/mapplications/#{mapplication.id}#post-#{id}"
    when Account
      account = commentable
      "#{ENV['BASE_URI']}/u/#{account.username}#post-#{id}"
    when Place
      place = commentable
      "#{ENV['BASE_URI']}/places/#{place.id}"
    when Organisation
      organisation = commentable
      "#{ENV['BASE_URI']}/o/#{organisation.slug}/members"
    when Activity
      activity = commentable
      "#{ENV['BASE_URI']}/activities/#{activity.id}"
    when LocalGroup
      local_group = commentable
      "#{ENV['BASE_URI']}/local_groups/#{local_group.id}"
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
    Account.and(:unsubscribed.ne => true).and(:id.in => subscriptions.pluck(:account_id))
  end
end
