module ActivityFeedbackSummaries
  extend ActiveSupport::Concern

  class_methods do
    def set_feedback_summaries
      # Activity.and(:feedback_summary.ne => nil).set(feedback_summary: nil)
      activities = Activity.and(:id.in => EventFeedback.pluck(:activity_id))
      activities = activities.select { |activity| activity.feedback_summary.nil? && activity.event_feedbacks.count >= 10 }
      activities.each_with_index do |activity, i|
        puts "#{i + 1}/#{activities.count} #{activity.organisation.name}: #{activity.name}"
        activity.feedback_summary!
      end

      ###
    end
  end

  def feedbacks_joined
    event_feedbacks.order('created_at desc').and(:answers.ne => nil).map do |ef|
      next unless ef.event
      next if ef.answers.all? { |_q, a| a.blank? }

      "# Feedback on #{ef.event.name}, #{ef.event.start_time}\n\n#{ef.answers.map { |q, a| "## #{q}\n#{a}" }.join("\n\n")}"
    end.compact.join("\n\n")
  end

  def feedback_summary!
    activity = self
    prompt = "Provide a one-paragraph summary of the feedback on this activity (family of events), #{activity.name}, hosted by #{activity.organisation.name}. Focus on the positives. The feedback:\n\n#{activity.feedbacks_joined}"

    last_paragraph = nil
    loop do
      response = OpenRouter.chat(prompt, max_tokens: 256)
      paragraphs = response.split("\n\n")
      if paragraphs.length <= 2
        last_paragraph = paragraphs.last.strip
        break if last_paragraph.split.length >= 50 && last_paragraph[0] != '-' && last_paragraph[0] != '*' && last_paragraph[-1] == '.'
      end
    end
    sentences = last_paragraph.split('. ')
    last_paragraph = sentences[1..-1].join('. ') if sentences[0] =~ /The feedback .* positive/ || sentences[0] =~ /positive feedback/
    puts "#{last_paragraph}\n\n"
    activity.set(feedback_summary: last_paragraph)
  end
end
