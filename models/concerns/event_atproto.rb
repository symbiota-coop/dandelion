module EventAtproto
  extend ActiveSupport::Concern

  ATPROTO_MODES = {
    virtual: 'community.lexicon.calendar.event#virtual',
    inperson: 'community.lexicon.calendar.event#inperson',
    hybrid: 'community.lexicon.calendar.event#hybrid'
  }.freeze

  ATPROTO_STATUSES = {
    scheduled: 'community.lexicon.calendar.event#scheduled',
    cancelled: 'community.lexicon.calendar.event#cancelled',
    planned: 'community.lexicon.calendar.event#planned',
    postponed: 'community.lexicon.calendar.event#postponed',
    rescheduled: 'community.lexicon.calendar.event#rescheduled'
  }.freeze

  included do
    after_create :publish_to_atproto, if: :should_publish_to_atproto?
    after_update :update_atproto, if: :should_update_atproto?
    before_destroy :delete_atproto, if: :atproto_uri?

    handle_asynchronously :publish_to_atproto
    handle_asynchronously :update_atproto
  end

  def should_publish_to_atproto?
    atproto_enabled? && !secret && !locked
  end

  def should_update_atproto?
    return false unless atproto_enabled? && atproto_fields_changed?

    # Trigger if we have an existing record to update, OR if secret/locked changed (to handle publish on unlock)
    atproto_uri.present? || (previous_changes.keys & %w[secret locked]).any?
  end

  def atproto_enabled?
    organisation&.atproto_connected? ||
      (ENV['ATPROTO_HANDLE'].present? && ENV['ATPROTO_APP_PASSWORD'].present?)
  end

  def atproto_client_for_publishing
    if organisation&.atproto_connected?
      organisation.atproto_client
    elsif ENV['ATPROTO_HANDLE'].present? && ENV['ATPROTO_APP_PASSWORD'].present?
      AtprotoClient.new
    end
  end

  def atproto_record_did
    atproto_uri&.split('/')&.[](2)
  end

  def atproto_client_for_record
    record_did = atproto_record_did
    return unless record_did

    return organisation.atproto_client if organisation&.atproto_connected? && organisation.atproto_did == record_did

    return AtprotoClient.new if ENV['ATPROTO_DID'] == record_did

    nil
  end

  def atproto_fields_changed?
    (previous_changes.keys & %w[name description start_time end_time location coordinates secret locked slug facebook_event_url]).any?
  end

  # Determine event mode: virtual or inperson
  def atproto_mode
    location == 'Online' ? ATPROTO_MODES[:virtual] : ATPROTO_MODES[:inperson]
  end

  # Determine event status (extensible for future cancellation support)
  def atproto_status
    # Future: check for cancelled/postponed fields when added
    ATPROTO_STATUSES[:scheduled]
  end

  # Build locations array supporting multiple location types
  def atproto_locations
    locations = []

    # Add physical geo location if available
    if location.present? && location != 'Online' && coordinates.present?
      locations << {
        '$type' => 'community.lexicon.location.geo',
        'latitude' => coordinates[1].to_s,
        'longitude' => coordinates[0].to_s,
        'name' => location
      }
    end

    locations.presence
  end

  # Build URIs array with event link and optional external links
  def atproto_uris
    uris = []

    # Primary event URI
    uris << {
      '$type' => 'community.lexicon.calendar.event#uri',
      'uri' => "#{ENV['BASE_URI']}/e/#{slug}",
      'name' => name
    }

    # Facebook event URL if present
    if facebook_event_url.present?
      uris << {
        '$type' => 'community.lexicon.calendar.event#uri',
        'uri' => facebook_event_url,
        'name' => 'Facebook event'
      }
    end

    uris
  end

  # Build the complete ATProto record
  def build_atproto_record
    record = {
      '$type' => 'community.lexicon.calendar.event',
      'name' => name,
      'createdAt' => created_at.utc.iso8601
    }

    record['description'] = ReverseMarkdown.convert(description).gsub('&nbsp;', ' ').strip if description.present?
    record['startsAt'] = start_time.utc.iso8601 if start_time
    record['endsAt'] = end_time.utc.iso8601 if end_time
    record['mode'] = atproto_mode
    record['status'] = atproto_status
    record['locations'] = atproto_locations if atproto_locations
    record['uris'] = atproto_uris

    record
  end

  def publish_to_atproto
    client = atproto_client_for_publishing
    return unless client

    record = build_atproto_record

    result = client.create_record(
      collection: 'community.lexicon.calendar.event',
      record: record
    )

    set(atproto_uri: result['uri']) if result['uri']
  rescue StandardError => e
    Honeybadger.notify(e, context: { event_id: id.to_s, action: 'publish' })
  end

  def update_atproto
    # If event became secret/locked, delete the ATProto record
    if secret? || locked?
      delete_atproto
      return
    end

    # If event became unsecret/unlocked and has no ATProto record, publish it
    if atproto_uri.blank?
      publish_to_atproto
      return
    end

    client = atproto_client_for_record
    return unless client

    record = build_atproto_record

    # Extract rkey from URI (at://did/collection/rkey)
    rkey = atproto_uri.split('/').last

    client.put_record(
      collection: 'community.lexicon.calendar.event',
      rkey: rkey,
      record: record
    )
  rescue StandardError => e
    Honeybadger.notify(e, context: { event_id: id.to_s, action: 'update' })
  end

  def delete_atproto
    return unless atproto_uri.present?

    client = atproto_client_for_record
    return unless client

    client.delete_record(uri: atproto_uri)
    set(atproto_uri: nil) unless destroyed?
  rescue StandardError => e
    Honeybadger.notify(e, context: { event_id: id.to_s, action: 'delete' })
  end
end
