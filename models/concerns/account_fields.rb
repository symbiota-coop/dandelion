module AccountFields
  extend ActiveSupport::Concern

  included do
    dragonfly_accessor :image do
      after_assign do |attachment|
        if attachment.image?
          if attachment.format == 'heic'
            attachment.convert('-format jpeg')
            attachment.name = "#{SecureRandom.uuid}.jpg"
          end

          attachment.process!(:thumb, '1920x1920>')
        end
      end
    end

    attr_accessor :password, :postcode, :country, :skip_confirmation_email, :gc_plan_id

    field :name, type: String
    field :name_transliterated, type: String
    field :email, type: String
    field :phone, type: String
    field :telegram_username, type: String
    field :username, type: String
    field :website, type: String
    field :gender, type: String
    field :sexuality, type: String
    field :date_of_birth, type: Date
    field :dietary_requirements, type: String
    field :time_zone, type: String
    field :crypted_password, type: String
    field :image_uid, type: String
    field :sign_ins_count, type: Integer
    field :sign_in_token, type: String
    field :api_key, type: String
    field :last_active, type: Time
    field :last_checked_notifications, type: Time
    field :last_checked_messages, type: Time
    field :location, type: String
    field :number_at_this_location, type: Integer
    field :coordinates, type: Array
    field :default_currency, type: String
    field :organisation_ids_cache, type: Array
    field :organisation_ids_public_cache, type: Array
    field :bio, type: String
    field :can_message, type: Mongoid::Boolean
    field :failed_sign_in_attempts, type: Integer
    field :minimal_head, type: String
    field :stripe_subscription_id, type: String
    field :feedback_summary, type: String
    field :youtube_video_url, type: String
    field :sent_first_event_email, type: Time
    field :event_feedbacks_as_facilitator_count, type: Integer
    field :event_tags_joined, type: String

    %w[email_confirmed
       updated_profile
       admin
       unsubscribed
       unsubscribed_messages
       unsubscribed_feedback
       unsubscribed_reminders
       open_to_hookups
       open_to_new_friends
       open_to_short_term_dating
       open_to_long_term_dating
       open_to_open_relating
       block_reply_by_email
       hidden
       seen_intro_tour
       can_reset_passwords].each do |b|
      field b.to_sym, type: Mongoid::Boolean
    end

    privacyables.each do |p|
      field :"#{p}_privacy", type: String
    end
  end

  class_methods do
    def admin_fields
      {
        email: :email,
        name: :text,
        name_transliterated: { type: :text, disabled: true },
        api_key: :text,
        updated_profile: :check_box,
        default_currency: :select,
        phone: :text,
        location: :text,
        number_at_this_location: :number,
        username: :text,
        website: :url,
        gender: :select,
        sexuality: :select,
        date_of_birth: :date,
        dietary_requirements: :text,
        image: :image,
        can_message: :check_box,
        email_confirmed: :check_box,
        admin: :check_box,
        unsubscribed: :check_box,
        unsubscribed_messages: :check_box,
        unsubscribed_feedback: :check_box,
        unsubscribed_reminders: :check_box,
        hidden: :check_box,
        block_reply_by_email: :check_box,
        can_reset_passwords: :check_box,
        password: :password,
        sign_ins_count: :number,
        failed_sign_in_attempts: :number,
        provider_links: :collection,
        memberships: :collection,
        mapplications: :collection,
        organisationships: :collection,
        tickets: :collection,
        orders: :collection,
        last_active: :datetime,
        stripe_subscription_id: :text,
        minimal_head: :text_area,
        youtube_video_url: :url
      }
    end

    def human_attribute_name(attr, options = {})
      {
        name: 'Full name',
        image: 'Photo',
        unsubscribed: 'Opt out of all emails from Dandelion',
        unsubscribed_messages: 'Opt out of email notifications of direct messages',
        unsubscribed_feedback: 'Opt out of requests for feedback',
        unsubscribed_reminders: 'Opt out of event reminders',
        hidden: 'Make my profile private and visible only to me',
        hear_about: 'How did you hear about this event?',
        gc_plan_id: 'Your plan',
        gc_given_name: 'First name on bank account',
        gc_family_name: 'Last name on bank account',
        gc_address_line1: 'Address line 1',
        gc_city: 'City',
        gc_postal_code: 'Post code',
        gc_branch_code: 'Sort code',
        gc_account_number: 'Account number'
      }[attr.to_sym] || super
    end

    def new_hints
      {
        location: 'Used for connecting you with events near you. Never displayed publicly without your consent.',
        date_of_birth: 'Never displayed publicly, though you can choose to show your age.',
        username: 'Letters, numbers, underscores and periods'
      }
    end

    def edit_hints
      {
        password: 'Leave blank to keep existing password'
      }.merge(new_hints)
    end

    def privacy_levels
      ['Only me', 'People I follow', 'Public']
    end

    def countries
      [''] + ISO3166::Country.all.sort
    end

    def open_to
      %w[new_friends hookups short_term_dating long_term_dating open_relating]
    end

    def privacyables
      %w[email location phone telegram_username website date_of_birth gender sexuality bio open_to last_active organisations local_groups activities gatherings following followers]
    end

    def sexualities
      [''] + %(Straight
  Gay
  Bisexual
  Asexual
  Demisexual
  Heteroflexible
  Homoflexible
  Lesbian
  Pansexual
  Queer
  Questioning
  Sapiosexual).split("\n").map(&:strip)
    end

    def genders
      [''] + %(Woman
  Man
  Agender
  Androgynous
  Bigender
  Cis Man
  Cis Woman
  Genderfluid
  Genderqueer
  Gender Nonconforming
  Hijra
  Intersex
  Non-binary
  Other
  Pangender
  Transfeminine
  Transgender
  Transmasculine
  Transsexual
  Trans Man
  Trans Woman
  Two Spirit).split("\n").map(&:strip)
    end
  end
end
