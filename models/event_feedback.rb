class EventFeedback
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paranoia

  belongs_to :event, index: true, optional: true
  belongs_to :activity, index: true, optional: true
  belongs_to :account, index: true

  field :answers, type: Array
  field :public, type: Boolean
  field :anonymise, type: Boolean
  field :public_answers, type: Array
  field :rating, type: Integer
  field :ps_event_feedback_id, type: String

  def self.admin_fields
    {
      rating: :radio,
      public: :check_box,
      anonymise: :check_box,
      answers: { type: :text_area, disabled: true },
      public_answers: { type: :text_area, disabled: true },
      event_id: :lookup,
      activity_id: :lookup,
      ps_event_feedback_id: :text,
      account_id: :lookup
    }
  end

  validates_uniqueness_of :event, scope: :account, allow_nil: true, conditions: -> { where(deleted_at: nil) }
  validates_uniqueness_of :ps_event_feedback_id, allow_nil: true

  after_save do
    event.clear_cache if event
  end
  after_destroy do
    event.clear_cache if event
  end

  before_validation do
    self.activity = event.activity if new_record? && !activity && event
  end

  def self.average_rating
    ratings = self.and(:rating.ne => nil).pluck(:rating)
    return unless ratings.length > 0

    ratings = ratings.map(&:to_i)
    (ratings.inject(:+).to_f / ratings.length).round(1)
  end

  def self.ratings
    1.upto(5).map do |i|
      [i.times.map { '<i class="fa fa-star"></i>' }.join, i]
    end.to_h
  end

  after_create :send_feedback
  def send_feedback
    return unless event

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    event_feedback = self
    event = event_feedback.event
    content = ERB.new(File.read(Padrino.root('app/views/emails/event_feedback.erb'))).result(binding)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject "#{event_feedback.rating.times.each.map { '★' }.join if event_feedback.rating} #{event.name}/#{event_feedback.anonymise? ? 'Anonymous' : event_feedback.account.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    event.accounts_receiving_feedback.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
  handle_asynchronously :send_feedback

  def send_destroy_notification(destroyed_by)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    event_feedback = self
    event = event_feedback.event
    content = ERB.new(File.read(Padrino.root('app/views/emails/event_feedback_destroyed.erb'))).result(binding)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject "#{destroyed_by.name} deleted feedback for #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    event.accounts_receiving_feedback.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
end
