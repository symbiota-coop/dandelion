class Event
  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paranoia
  extend Dragonfly::Model

  include EventFields
  include EventAssociations
  include EventCallbacks
  include EventScopes
  include EventAccounting
  include EventDuplication
  include EventNotifications
  include EventOpenCollective
  include EventValidation
  include EventAccessControl
  include Geocoded

  def self.fs(slug)
    find_by(slug: slug)
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def self.public
    self.and(:secret.ne => true).and(:organisation_id.ne => nil)
  end

  def page_views_count
    PageView.or({ path: "/e/#{slug}" }, { path: "/events/#{id}" }).count
  end

  def token
    Token.all.find { |token| token.symbol == currency }
  end

  def chain
    if currency == 'USD'
      Chain.object('Gnosis Chain')
    else
      token.try(:chain)
    end
  end

  def questions_a
    q = (questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  def recording?
    past? && extra_info_for_recording_email
  end

  def summary
    start_time ? "#{name} (#{start_time.to_date})" : name
  end

  def feedback_questions_a
    q = (feedback_questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  def future?(from = Date.today)
    start_time >= from
  end

  def past?(from = Date.today)
    start_time < from
  end

  def finished?(from = Date.today)
    end_time < from
  end

  def online?
    location == 'Online'
  end

  def in_person?
    location != 'Online'
  end

  def paid_tickets?
    ticket_types.any? { |ticket_type| (ticket_type.price && ticket_type.price > 0) || ticket_type.range }
  end

  def live?
    !locked?
  end

  def public?
    !secret?
  end

  def sold_out?
    ticket_types.count > 0 && ticket_types.and(:hidden.ne => true).all? { |ticket_type| ticket_type.number_of_tickets_available_in_single_purchase <= 0 }
  end

  def tickets_available?
    ticket_types.count > 0 && ticket_types.and(:hidden.ne => true).any? { |ticket_type| ticket_type.number_of_tickets_available_in_single_purchase >= 1 }
  end

  def places_remaining
    capacity - tickets.count if capacity
  end

  def time_zone_or_default
    time_zone || organisation.try(:time_zone) || ENV['DEFAULT_TIME_ZONE']
  end

  after_save :clear_cache
  def clear_cache
    Fragment.and(key: %r{/events/#{id}}).destroy_all
  end

  def carousel_name
    return unless organisation && organisation.carousels

    c = nil
    organisation.carousels.order('o desc').each do |carousel|
      next if carousel.name.downcase.include?('past events')

      intersection = event_tags.pluck(:id) & carousel.event_tags.pluck(:id)
      if intersection.count > 0
        c = carousel.name
        break
      end
    end
    c
  end

  def when_details(zone, with_zone: true)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_fs(:no_double_zeros)} #{z if with_zone}"
    else
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_date}, #{end_time.to_fs(:no_double_zeros)} #{z if with_zone}"
    end
  end

  def concise_when_details(zone, with_zone: false)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      start_time.to_date
    else
      "#{start_time.to_date} – #{end_time.to_date} #{z if with_zone}"
    end
  end

  def ical(order: nil)
    event = self
    cal = Icalendar::Calendar.new
    cal.append_custom_property('METHOD', 'REQUEST') if order
    cal.event do |e|
      e.summary = (event.start_time.to_date == event.end_time.to_date ? event.name : "#{event.name} starts")
      e.dtstart = (event.start_time.to_date == event.end_time.to_date ? event.start_time.utc.strftime('%Y%m%dT%H%M%SZ') : Icalendar::Values::Date.new(event.start_time.to_date))
      e.dtend = (event.start_time.to_date == event.end_time.to_date ? event.end_time.utc.strftime('%Y%m%dT%H%M%SZ') : nil)
      e.transp = (event.start_time.to_date == event.end_time.to_date ? 'OPAQUE' : 'TRANSPARENT')
      e.location = event.location
      e.description = order ? %(#{ENV['BASE_URI']}/orders/#{order.id}) : %(#{ENV['BASE_URI']}/events/#{event.id})
      e.organizer = event.email
      e.uid = event.id.to_s
      if order
        e.status = 'CONFIRMED'
        e.attendee = Icalendar::Values::CalAddress.new(
          "mailto:#{order.account.email}",
          cn: order.account.email,
          role: 'REQ-PARTICIPANT',
          partstat: 'ACCEPTED',
          cutype: 'INDIVIDUAL'
        )
      end
    end
    cal
  end

  after_save :update_event_tags
  def update_event_tags
    return unless @update_tag_names

    @tag_names ||= ''
    @tag_names_a = @tag_names.split(',').map { |tag_name| tag_name.strip }
    current_tag_names = event_tagships.map(&:event_tag_name)
    tags_to_remove = current_tag_names - @tag_names_a
    tags_to_add = @tag_names_a - current_tag_names
    tags_to_remove.each do |name|
      event_tag = EventTag.find_by(name: name)
      event_tagships.find_by(event_tag: event_tag).destroy
    end
    tags_to_add.each do |name|
      if (event_tag = EventTag.find_or_create_by(name: name)).persisted?
        event_tagships.create(event_tag: event_tag)
      end
    end
  end

  after_save :ai_tag
  def ai_tag
    return if duplicate
    return unless event_tagships(true).empty?

    prompt = "Provide a list of 5 tags for this event as a comma-separated list. Use spaces. No hashtags. Event details: \n\n#{name}\n\n#{description}"

    return unless ENV['ANTHROPIC_API_KEY']

    prompt = prompt[0..(200_000 * 0.66 * 4)]
    client = Anthropic::Client.new
    content = nil
    5.times do
      response = client.messages(
        parameters: {
          model: 'claude-3-haiku-20240307',
          messages: [
            { role: 'user', content: prompt }
          ],
          max_tokens: 256
        }
      )
      if response['content']
        content = response['content'].first['text']
        break unless content.include?('#')
      else
        puts 'sleeping...'
        sleep 5
      end
    end
    return unless content

    content.split(':').last.strip.split(',').map(&:strip).map do |name|
      name.gsub('_', ' ').gsub('-', ' ').downcase
    end.each do |name|
      puts name
      if (event_tag = EventTag.find_or_create_by(name: name)).persisted?
        event_tagships.create(event_tag: event_tag)
      end
    end
    set(ai_tagged: true)

    # prompt = prompt[0..(128_000 * 0.66 * 4)]
    # client = OpenAI::Client.new
    # content = nil
    # 5.times do
    #   response = client.chat(
    #     parameters: {
    #       model: 'gpt-4o-mini',
    #       messages: [{ role: 'user', content: prompt }],
    #       max_tokens: 256
    #     }
    #   )
    #   if (content = response.dig('choices', 0, 'message', 'content'))
    #     break unless content.include?('#')
    #   else
    #     puts 'sleeping...'
    #     sleep 1
    #   end
    # end
    # return unless content

    # prompt = prompt[0..(1_000_000 * 0.66 * 4)]
    # content = nil
    # 5.times do
    #   response = GEMINI_FLASH.generate_content(
    #     {
    #       contents: { role: 'user', parts: { text: prompt } },
    #       generationConfig: { maxOutputTokens: 256 }
    #     }
    #   )
    #   if (content = response.dig('candidates', 0, 'content', 'parts', 0, 'text'))
    #     break unless content.include?('#')
    #   else
    #     puts 'sleeping...'
    #     sleep 1
    #   end
    # end
    # return unless content
  end
end
