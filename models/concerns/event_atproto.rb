module EventAtproto
  extend ActiveSupport::Concern

  class_methods do
    # Sync events created or modified in the last X hours to AT Protocol
    # Useful for catching up after AT Protocol endpoints were temporarily offline
    #
    # @param hours [Integer] number of hours to look back (default: 24)
    # @param dry_run [Boolean] if true, just returns the events that would be synced
    # @return [Hash] results with :published, :updated, :deleted, :skipped, :errors counts
    def sync_atproto(hours: 24, dry_run: false)
      cutoff = hours.hours.ago
      results = { published: 0, updated: 0, deleted: 0, skipped: 0, errors: [], dry_run: dry_run }

      # Find events created or updated since the cutoff
      events = Event.or(
        { created_at: { '$gte' => cutoff } },
        { updated_at: { '$gte' => cutoff } }
      )

      events.each do |event|
        sync_result = event.sync_to_atproto(dry_run: dry_run)
        case sync_result[:action]
        when :published
          results[:published] += 1
        when :updated
          results[:updated] += 1
        when :deleted
          results[:deleted] += 1
        when :skipped
          results[:skipped] += 1
        when :error
          results[:errors] << { event_id: event.id.to_s, error: sync_result[:error] }
        end
      rescue StandardError => e
        results[:errors] << { event_id: event.id.to_s, error: e.message }
      end

      results
    end
  end

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

  ATPROTO_COLLECTION = 'community.lexicon.calendar.event'.freeze
  ATPROTO_TRACKED_FIELDS = %w[name description start_time end_time location coordinates secret locked slug facebook_event_url].freeze
  ATPROTO_VISIBILITY_FIELDS = %w[secret locked].freeze

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
    atproto_uri.present? || previous_changes.keys.intersect?(ATPROTO_VISIBILITY_FIELDS)
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
    previous_changes.keys.intersect?(ATPROTO_TRACKED_FIELDS)
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
      '$type' => ATPROTO_COLLECTION,
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

    result = client.create_record(collection: ATPROTO_COLLECTION, record: record)

    set(atproto_uri: result['uri']) if result['uri']
  rescue StandardError => e
    Honeybadger.notify(e, context: { event_id: id.to_s, action: 'publish' })
  end

  def update_atproto(force: false)
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

    # Skip if no relevant fields changed (unless force is true)
    return if !force && !atproto_fields_changed?

    client = atproto_client_for_record
    return unless client

    record = build_atproto_record

    client.put_record(uri: atproto_uri, record: record)
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

  # Sync this event to AT Protocol, determining the appropriate action
  # Returns a hash with :action and optionally :error
  #
  # @param dry_run [Boolean] if true, just returns what would happen without executing
  # @return [Hash] { action: :published | :updated | :deleted | :skipped, error: String? }
  def sync_to_atproto(dry_run: false)
    # Event should not be on AT Protocol (secret/locked)
    if secret? || locked?
      if atproto_uri.present?
        delete_atproto unless dry_run
        return { action: :deleted }
      end
      return { action: :skipped, reason: 'secret_or_locked' }
    end

    # Event should be on AT Protocol
    return { action: :skipped, reason: 'atproto_not_enabled' } unless atproto_enabled?

    if atproto_uri.blank?
      # Never published - publish now
      publish_to_atproto unless dry_run
      return { action: :published }
    end

    # Already published - refresh the record
    update_atproto(force: true) unless dry_run
    { action: :updated }
  rescue StandardError => e
    Honeybadger.notify(e, context: { event_id: id.to_s, action: 'sync' })
    { action: :error, error: e.message }
  end
end
