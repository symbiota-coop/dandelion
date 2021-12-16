class Comment
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :account, index: true, inverse_of: :comments_as_creator
  belongs_to :post, index: true
  belongs_to :commentable, polymorphic: true, index: true

  field :body, type: String
  field :file_uid, type: String
  field :force, type: Boolean
  field :sent_at, type: Time

  def self.admin_fields
    {
      body: :text_area,
      file: :file,
      force: :check_box,
      account_id: :lookup,
      sent_at: :datetime,
      commentable_id: :text,
      commentable_type: :select,
      post_id: :lookup
    }
  end

  def self.commentable_types
    Post.commentable_types
  end

  attr_accessor :via_email

  dragonfly_accessor :file

  has_many :comment_reactions, dependent: :destroy
  has_many :voptions, dependent: :destroy
  has_many :read_receipts, dependent: :destroy
  has_many :photos, as: :photoable, dependent: :destroy

  after_create do
    post.subscriptions.create account: account
    if body
      body.scan(/\[@[\w\s'-.]+\]\(@(\w+)\)/) do |match|
        post.subscriptions.create account: Account.find_by(username: match[0])
      end
    end
  end

  def body_with_additions
    if body
      b = body
      b = b.gsub("\n", '<br />')
      b.gsub(/\[@([\w\s'-.]+)\]\(@(\w+)\)/, '<a href="' + ENV['BASE_URI'] + '/u/\2">\1</a>')

    end
  end

  has_many :notifications, as: :notifiable, dependent: :destroy
  after_create do
    notifications.create! circle: circle, type: 'commented' if circle
  end

  def allow_force?(account)
    if commentable.is_a?(Team)
      team = commentable
      gathering = team.gathering
      true if (membership = gathering.memberships.find_by(account: account)) && membership.admin?
    elsif commentable.is_a?(Gathering)
      gathering = commentable
      true if (membership = gathering.memberships.find_by(account: account)) && membership.admin?
    else
      false
    end
  end

  def self.admin?(comment, account)
    comment && account && (
      if %w[Organisation].include?(comment.commentable_type)
        Organisation.admin?(comment.commentable, account)
      elsif %w[Activity].include?(comment.commentable_type)
        Activity.admin?(comment.commentable, account)
      elsif %w[LocalGroup].include?(comment.commentable_type)
        LocalGroup.admin?(comment.commentable, account)
      elsif %w[Gathering].include?(comment.commentable_type)
        Gathering.admin?(comment.commentable, account)
      elsif %w[Team Tactivity Mapplication].include?(comment.commentable_type)
        Gathering.admin?(comment.commentable.gathering, account)
      elsif %w[Account].include?(comment.commentable_type)
        comment.commentable_id == account.id
      elsif %w[Place Habit].include?(comment.commentable_type)
        comment.commentable.account_id == account.id
      end
    )
  end

  def circle
    if %w[Team Tactivity Mapplication].include?(commentable_type)
      commentable.gathering
    elsif %w[Account Gathering Activity LocalGroup Organisation Place].include?(commentable_type)
      commentable
    elsif %w[Habit].include?(commentable_type)
      commentable.account
    end
  end

  def name
    post.subject
  end

  after_create do
    PUSHER.trigger("post.#{post.id}", 'updated', {}) if defined?(PUSHER)
  end

  after_destroy do
    PUSHER.trigger("post.#{post.id}", 'updated', {}) if defined?(PUSHER)
  end

  before_validation do
    self.commentable = post.commentable if post

    if post && (previous_comment = post.comments(true).last) && previous_comment.body == body
      errors.add(:body, 'cannot be a duplicate')
      account.set(block_reply_by_email: true) if via_email
    end
  end

  def description
    if commentable.is_a?(Mapplication)
      "<strong>#{account.name}</strong> commented on <strong>#{commentable.account.name}</strong>'s application"
    elsif post.comments.count == 1
      "<strong>#{account.name}</strong> started a thread"
    else
      "<strong>#{account.name}</strong> replied"
    end.html_safe
  end

  def first_in_post?
    !post or post.new_record? or post.comments.order('created_at asc').first.id == id
  end

  def first_in_post
    post.comments.order('created_at asc').first
  end

  after_create do
    post.update_attribute(:updated_at, Time.now)
  end

  def email_subject
    s = ''
    if commentable.is_a?(Event)
      event = commentable
      s << "[#{event.name}] "
    elsif commentable.is_a?(LocalGroup)
      local_group = commentable
      s << "[#{local_group.organisation.name}/#{local_group.name}] "
    elsif commentable.is_a?(Activity)
      activity = commentable
      s << "[#{activity.organisation.name}/#{activity.name}] "
    elsif commentable.is_a?(Organisation)
      organisation = commentable
      s << "[#{organisation.name}] "
    elsif commentable.is_a?(ActivityApplication)
      activity_application = commentable
      s << "[#{activity_application.activity.organisation.name}/#{activity_application.activity.name}/#{activity_application.account.name}] "
    elsif commentable.is_a?(Place)
      place = commentable
      s << "[Places/#{place.name}] "
    elsif commentable.is_a?(Gathering)
      gathering = commentable
      s << "[#{gathering.name}] "
    elsif commentable.is_a?(Habit)
      habit = commentable
      s << "[#{habit.account.name}/#{habit.name}] "
    elsif commentable.is_a?(Account)
      account = commentable
      s << "[#{account.name}] "
    elsif commentable.respond_to?(:gathering)
      s << '['
      s << commentable.gathering.name
      if commentable.is_a?(Team)
        team = commentable
        s << '/'
        s << team.name
      elsif commentable.is_a?(Tactivity)
        tactivity = commentable
        s << '/'
        s << tactivity.timetable.name
        s << '/'
        s << tactivity.name
      elsif commentable.is_a?(Mapplication)
        mapplication = commentable
        s << '/'
        s << "#{mapplication.account.name}'s application"
      end
      s << '] '
    end
    s << if first_in_post?
           post.subject
         else
           "Re: #{post.subject}"
         end
  end

  after_create :send_comment, if: proc { |comment| !comment.commentable.respond_to?(:auto_comment_sending) || comment.commentable.auto_comment_sending }
  def send_comment
    return if sent_at

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'posts.dandelion.earth')

    comment = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/comment.erb'))).result(binding)
    batch_message.from "Dandelion <#{comment.post_id}@posts.dandelion.earth>"
    batch_message.subject comment.email_subject
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    accounts = Account.public
    accounts = accounts.and(:unsubscribed.ne => true) unless force
    accounts = accounts.and(:id.in => post.subscriptions.pluck(:account_id))
    accounts.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    update_attribute(:sent_at, Time.now)
  end
  handle_asynchronously :send_comment

  def self.human_attribute_name(attr, options = {})
    {
      force: 'Send to people that have unsubscribed from Dandelion emails (use with care!)'
    }[attr.to_sym] || super
  end
end
