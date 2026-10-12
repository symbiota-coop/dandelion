module EventsSummary
  GENERAL_INSTRUCTIONS = 'Do not mention specific dates or times. Return well-formatted markdown. Do not use italics. Do not use headers. Link all event names using proper markdown syntax like [Event Name](URL).'.freeze

  # Markdown summarising the events (or their feedback), or nil if the model didn't answer
  def self.generate(prompt_prefix, events, use_feedback: false, general_instructions: GENERAL_INSTRUCTIONS)
    output = ''
    seen_event_names = Set.new

    events.each do |event|
      next if use_feedback && event.event_feedbacks.empty?
      next if seen_event_names.include?(event.name.split(':').first)

      seen_event_names.add(event.name.split(':').first)

      output << "# #{event.name}, #{event.when_details(ENV['DEFAULT_TIME_ZONE'])} at #{event.location}\n"
      output << "URL: #{ENV['BASE_URI']}/e/#{event.slug}\n\n"
      output << (use_feedback ? event.event_feedbacks.joined(base_header: '#') : (event.description || ''))
      output << "\n\n"
    end

    prompt = %(#{prompt_prefix}\n\n#{general_instructions}\n\n#{output})

    result = OpenRouter.chat(prompt)
    return if result.nil?

    # Remove first paragraph if starts with 'Here' or ends with a colon
    paragraphs = result.split("\n\n")
    if paragraphs.first&.strip&.start_with?('Here') || paragraphs.first&.strip&.end_with?(':')
      paragraphs.shift
      result = paragraphs.join("\n\n")
    end

    result
  end
end
