module ActivityFeedbackSummaries
  extend ActiveSupport::Concern

  class_methods do
    def set_feedback_summaries
      # Activity.and(:feedback_summary.ne => nil).update_all(feedback_summary: nil)
      activities = Activity.and(:id.in => EventFeedback.pluck(:activity_id), :feedback_summary => nil)
      activities = activities.select { |activity| activity.event_feedbacks.count >= 10 }
      activities.each_with_index do |activity, i|
        puts "#{i + 1}/#{activities.count} #{activity.organisation.name}: #{activity.name}"
        activity.feedback_summary!
      end
    end
  end

  def feedback_summary!
    activity = self
    prompt = "Provide a one-paragraph summary of the feedback on this activity (family of events), #{activity.name}, hosted by #{activity.organisation.name}. Focus on the positives. The feedback:\n\n#{activity.event_feedbacks.joined}"

    last_paragraph = nil
    loop do
      response = OpenRouter.chat(prompt, max_tokens: 256)
      next if response.nil?

      paragraphs = response.split("\n\n")
      if paragraphs.length <= 2
        last_paragraph = paragraphs.last.strip
        break if last_paragraph.split.length >= 50 && last_paragraph[0] != '-' && last_paragraph[0] != '*' && last_paragraph[-1] == '.'
      end
    end
    sentences = last_paragraph.split('. ')
    last_paragraph = sentences[1..-1].join('. ') if sentences[0] =~ /The feedback .* positive/ || sentences[0] =~ /positive feedback/
    puts "#{last_paragraph}\n\n"
    activity.update_attribute(:feedback_summary, last_paragraph)
  end
end
