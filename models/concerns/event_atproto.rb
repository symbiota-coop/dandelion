module EventAtproto
  extend ActiveSupport::Concern

  included do
    field :atproto_uri, type: String

    after_create :publish_to_atproto, if: :should_publish_to_atproto?
  end

  def should_publish_to_atproto?
    ENV['ATPROTO_HANDLE'].present? &&
      ENV['ATPROTO_APP_PASSWORD'].present? &&
      !secret && !locked
  end

  def publish_to_atproto
    client = AtprotoClient.new

    record = {
      '$type' => 'community.lexicon.calendar.event',
      'name' => name,
      'createdAt' => Time.now.utc.iso8601
    }

    record['description'] = ReverseMarkdown.convert(description).strip if description.present?
    record['startsAt'] = start_time.utc.iso8601 if start_time
    record['endsAt'] = end_time.utc.iso8601 if end_time
    record['mode'] = location == 'Online' ? 'virtual' : 'in-person'
    record['status'] = 'scheduled'

    record['locations'] = [{ 'name' => location }] if location.present? && location != 'Online'

    record['uris'] = [{
      'uri' => "#{ENV['BASE_URI']}/e/#{slug}",
      'name' => name
    }]

    result = client.create_record(
      collection: 'community.lexicon.calendar.event',
      record: record
    )

    set(atproto_uri: result['uri']) if result['uri']
  rescue StandardError => e
    Honeybadger.notify(e, context: { event_id: id.to_s })
  end
end
