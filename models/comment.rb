class Comment
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include RejectsActiveContent

  extend Dragonfly::Model

  belongs_to_without_parent_validation :account, inverse_of: :comments_as_creator
  belongs_to_without_parent_validation :post
  belongs_to_without_parent_validation :commentable, polymorphic: true

  field :body, type: String
  field :file_uid, type: String
  field :force, type: Boolean
  field :sent_at, type: Time


  def self.commentable_types
    Post.commentable_types
  end

  def self.protected_attributes
    %w[force sent_at]
  end

  attr_accessor :via_email

  # A chat comment is only its body, while a thread can open with only a subject
  validates_presence_of :body, if: :chat?

  dragonfly_accessor :file

  has_many :comment_reactions, dependent: :destroy
  has_many :voptions, dependent: :destroy
  has_many :read_receipts, dependent: :destroy
  has_many :photos, as: :photoable, dependent: :destroy

  after_create do
    post.subscriptions.create account: account
    mentioned_accounts.each_value do |mentioned|
      post.subscriptions.create account: mentioned
    end
  end

  # @username, not straight after a letter, dot or @, so email addresses don't count
  MENTION_REGEX = /(?<![\w.@])@([a-z0-9_.]+)/i

  # Accounts mentioned in the body, by username
  def mentioned_accounts
    @mentioned_accounts ||= mention_tokens.filter_map { |token| mentioned_account(token) }.uniq.index_by(&:username)
  end

  # The body as HTML, with mentions of accounts shown as their names, linked to their profiles
  def body_html(base_uri: '')
    return unless body

    ERB::Util.html_escape(body).to_str.gsub(MENTION_REGEX) do
      token = Regexp.last_match(1)
      next "@#{token}" unless (mentioned = mentioned_account(token))

      "<a href=\"#{base_uri}/u/#{mentioned.username}\">#{ERB::Util.html_escape(mentioned.name)}</a>#{token[mentioned.username.length..]}"
    end.html_safe
  end

  def mention_tokens
    body ? body.scan(MENTION_REGEX).flatten.map(&:downcase) : []
  end

  # Usernames can end in a dot, so '@jo.' is jo. if there's a jo., and otherwise jo at the end of a sentence
  def mentioned_account(token)
    @mention_candidates ||= begin
      usernames = mention_tokens.flat_map { |t| [t, t.sub(/\.+\z/, '')] }.uniq
      usernames.any? ? Account.and(:username.in => usernames).index_by(&:username) : {}
    end
    token = token.downcase
    @mention_candidates[token] || @mention_candidates[token.sub(/\.+\z/, '')]
  end

  def body_with_additions
    return unless body

    EmailHelper.untrusted(body_html(base_uri: ENV['BASE_URI'])).gsub("\n", '<br />').html_safe
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
    else
      false
    end
  end

  def self.admin?(comment, account, gathering_admin: nil)
    comment && account && (
      if %w[Team Tactivity Mapplication].include?(comment.commentable_type)
        gathering_admin || (gathering_admin.nil? && Gathering.admin?(comment.commentable.gathering, account))
      end
    )
  end

  def circle
    return unless %w[Team Tactivity Mapplication].include?(commentable_type)

    commentable.gathering
  end

  def name
    post.subject
  end

  before_validation do
    self.commentable = post.commentable if post

    if new_record? && post && (previous_comment = post.comments(true).last) && previous_comment.body == body
      errors.add(:body, 'cannot be a duplicate')
      account.set(block_reply_by_email: true) if via_email
    end
  end

  def description
    name = ERB::Util.html_escape(account.name)
    if commentable.is_a?(Mapplication)
      "<strong>#{name}</strong> commented on <strong>#{ERB::Util.html_escape(commentable.account.name)}</strong>'s application"
    elsif !chat? && post.comments.count == 1
      "<strong>#{name}</strong> started a thread"
    elsif first_real_comment?
      "<strong>#{name}</strong> commented"
    else
      "<strong>#{name}</strong> replied"
    end.html_safe
  end

  # An event's discussion is one chat rather than threads, so none of its comments starts one
  def chat?
    commentable_type == 'Event'
  end

  def first_in_post?
    return false if chat?

    !post || post.new_record? || ((comment = post.comments.order('created_at asc').first) && comment.id == id)
  end

  def first_in_post
    post.comments.order('created_at asc').first
  end

  # The first comment with a body: a thread can open with only a subject
  def first_real_comment?
    post.comments.and(:body.ne => nil).order('created_at asc').first&.id == id
  end

  after_create do
    post.set(updated_at: Time.now)
  end

  def email_subject
    s = ''
    if commentable.is_a?(Event)
      event = commentable
      s << "[#{event.name}] "
    elsif commentable.is_a?(ActivityApplication)
      activity_application = commentable
      s << "[#{activity_application.activity.organisation.name}/#{activity_application.activity.name}/#{activity_application.account.name}] "
    elsif commentable.respond_to?(:gathering)
      s << '['
      s << commentable.gathering.name
      case commentable
      when Team
        team = commentable
        s << '/'
        s << team.name
      when Tactivity
        tactivity = commentable
        s << '/'
        s << tactivity.timetable.name
        s << '/'
        s << tactivity.name
      when Mapplication
        mapplication = commentable
        s << '/'
        s << "#{mapplication.account.name}'s application"
      end
      s << '] '
    end
    s << if first_in_post? || first_real_comment?
           post.subject
         else
           "Re: #{post.subject}"
         end
  end

  after_create :send_comment
  def send_comment
    return if body.nil?
    return if sent_at

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_POSTS_HOST'])

    comment = self
    batch_message.from "Dandelion <#{comment.post_id}@#{ENV['MAILGUN_POSTS_HOST']}>"
    batch_message.subject comment.email_subject
    batch_message.body_html EmailHelper.html(:comment, comment: comment)

    accounts = Account.publicly_visible
    accounts = accounts.and(unsubscribed: false) unless force
    accounts = accounts.and(:id.in => post.subscriptions.pluck(:account_id))
    accounts.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.link_token_for_email, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
    set(sent_at: Time.now)
  end
  handle_asynchronously :send_comment

  def self.human_attribute_name(attr, options = {})
    {
      force: 'Send to people that have unsubscribed from Dandelion emails (use with care!)'
    }[attr.to_sym] || super
  end
end

