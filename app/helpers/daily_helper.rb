Dandelion::App.helpers do
  def render_article(title, prompt_prefix, events, use_feedback: false)
    return if events.empty?
    return if use_feedback && events.all? { |event| event.event_feedbacks.empty? }

    content = <<-HTML
      <div class="article">
        <h2 class="article-title">#{title}</h2>
        <div class="article-content">
          #{md(generate_events_summary(prompt_prefix, events, use_feedback: use_feedback))}
        </div>
      </div>
    HTML

    content.html_safe
  end

  def generate_events_summary(prompt_prefix, events, use_feedback: false, general_instructions: 'Do not mention specific dates or times. Return well-formatted markdown. Do not use italics. Do not use headers. Link all event names using proper markdown syntax like [Event Name](URL).')
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
    return '' if result.nil?

    # Remove first paragraph if starts with 'Here' or ends with a colon
    paragraphs = result.split("\n\n")
    if paragraphs.first&.strip&.start_with?('Here') || paragraphs.first&.strip&.end_with?(':')
      paragraphs.shift
      result = paragraphs.join("\n\n")
    end

    result
  end
end
