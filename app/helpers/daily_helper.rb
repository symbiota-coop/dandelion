Dandelion::App.helpers do
  def render_article(title, prompt_prefix, events, use_feedback: false)
    return if events.empty?
    return if use_feedback && events.event_feedbacks.empty?

    markdown = Redcarpet::Markdown.new(Redcarpet::Render::HTML, autolink: true, tables: true, fenced_code_blocks: true)
    content = <<-HTML
      <div class="article">
        <h2 class="article-title">#{title}</h2>
        <div class="article-content">
          #{markdown.render(generate_events_summary(prompt_prefix, events, use_feedback: use_feedback))}
        </div>
      </div>
    HTML

    content.html_safe
  end

  def generate_events_summary(prompt_prefix, events, use_feedback: false)
    output = ''
    events.each do |event|
      output << "# #{event.name}, #{event.when_details(ENV['DEFAULT_TIME_ZONE'])} at #{event.location}\n"
      output << "URL: #{ENV['BASE_URI']}/e/#{event.slug}\n\n"
      output << (use_feedback ? event.event_feedbacks.joined(base_header: '#') : event.description)
      output << "\n\n"
    end

    general_instructions = 'Do not mention specific times. Return well-formatted markdown. Do not use italics. Do not use headers. Link all event names using proper markdown syntax like [Event Name](URL).'
    prompt = %(#{prompt_prefix}\n\n#{general_instructions}\n\n#{output})

    OpenRouter.chat(prompt, model: 'google/gemini-flash-1.5').split("\n\n").last(2).join("\n\n")
  end
end
