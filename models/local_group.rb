class LocalGroup
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :organisation, index: true
  belongs_to :account, index: true

  field :name, type: String
  field :telegram_group, type: String
  field :intro_text, type: String
  field :geometry, type: String
  field :hide_members, type: Boolean
  field :hide_discussion, type: Boolean
  field :type, type: String

  def self.admin_fields
    {
      name: :text,
      type: :text,
      telegram_group: :url,
      intro_text: :wysiwyg,
      geometry: :text_area,
      hide_members: :check_box,
      hide_discussion: :check_box
    }
  end

  validates_presence_of :name, :geometry

  has_many :discount_codes, class_name: 'DiscountCode', as: :codeable, dependent: :destroy

  has_many :events, dependent: :nullify
  has_many :local_groupships, dependent: :destroy
  has_many :pmails, as: :mailable, dependent: :destroy
  def pmails_including_events
    Pmail.and(:id.in => pmails.pluck(:id) + Pmail.and(:mailable_type => 'Event', :mailable_id.in => events.pluck(:id)).pluck(:id))
  end

  has_many :zoomships, dependent: :destroy

  embeds_many :polygons

  before_validation do
    begin
      polygons.destroy_all
      g = JSON.parse(geometry)
      unless g['coordinates']
        g = g['features'].first['geometry']
        self.geometry = g.to_json
      end
      g['coordinates'].each do |polygon|
        polygons.build coordinates: (g['type'] == 'Polygon' ? [polygon] : polygon)
      end
    rescue StandardError => e
      errors.add(:geometry, e)
    end
  end

  before_validation do
    errors.add(:organisation, '- you are not an admin of this organisation') if organisation && !Organisation.admin?(organisation, account)
  end

  def event_tags
    EventTag.and(:id.in => EventTagship.and(:event_id.in => events.pluck(:id)).pluck(:event_tag_id))
  end

  def import_from_csv(csv)
    CSV.parse(csv, headers: true, header_converters: [:downcase, :symbol]).each do |row|
      email = row[:email]
      account_hash = { name: row[:name], email: row[:email], password: Account.generate_password }
      account = Account.find_by(email: email.downcase)
      account ||= Account.new(account_hash)
      begin
        if account.persisted?
          account.update_attributes!(Hash[account_hash.map { |k, v| [k, v] if v }.compact])
        else
          account.save!
        end
        local_groupships.create account: account
      rescue StandardError
        next
      end
    end
  end

  def event_feedbacks
    EventFeedback.and(:event_id.in => events.pluck(:id))
  end

  def members
    Account.and(:id.in => local_groupships.pluck(:account_id))
  end

  def organisation_members_within
    organisation.members.and(coordinates: { '$geoWithin' => { '$geometry' => JSON.parse(geometry) } })
  end

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  def self.admin?(local_group, account)
    account && local_group &&
      (
        account.admin? ||
        local_group.local_groupships.find_by(account: account, admin: true) ||
        Organisation.admin?(local_group.organisation, account)
      )
  end

  def discussers
    Account.and(:id.in => local_groupships.and(subscribed_discussion: true).pluck(:account_id))
  end

  def subscribed_members
    Account.and(:id.in => local_groupships.and(:unsubscribed.ne => true).pluck(:account_id))
  end

  def subscribed_accounts
    subscribed_members.and(:id.in => organisation.subscribed_accounts.pluck(:id))
  end

  def unsubscribed_members
    Account.and(:id.in => local_groupships.and(unsubscribed: true).pluck(:account_id))
  end

  def admins
    Account.and(:id.in => local_groupships.and(admin: true).pluck(:account_id))
  end

  def admins_receiving_feedback
    Account.and(:id.in => local_groupships.and(admin: true).and(receive_feedback: true).pluck(:account_id))
  end

  def send_followers_csv(account)
    csv = CSV.generate do |csv|
      csv << %w[name email unsubscribed]
      local_groupships.each do |local_groupship|
        csv << [
          local_groupship.account.name,
          Organisation.admin?(organisation, account) ? local_groupship.account.email : '',
          local_groupship.unsubscribed
        ]
      end
    end

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
    batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

    content = ERB.new(File.read(Padrino.root('app/views/emails/csv.erb'))).result(binding)
    batch_message.from 'Dandelion <notifications@dandelion.earth>'
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'followers.csv')

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    file.close
    file.unlink
  end
  handle_asynchronously :send_followers_csv
end
