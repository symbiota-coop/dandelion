module OrganisationFeedbackSummaries
  extend ActiveSupport::Concern

  class_methods do
    def set_feedback_summaries
      # Organisation.and(:feedback_summary.ne => nil).update_all(feedback_summary: nil)
      organisations = Organisation.and(feedback_summary: nil)
      organisations = organisations.select { |organisation| organisation.event_feedbacks.count >= 10 }
      organisations.each_with_index do |organisation, i|
        puts "#{i + 1}/#{organisations.count} #{organisation.name}"
        organisation.feedback_summary!
      end
    end
  end

  def feedback_summary!
    organisation = self
    prompt = "Provide a one-paragraph summary of the feedback on the events of this organisation, #{organisation.name}. Focus on the positives. The feedback:\n\n#{organisation.event_feedbacks.joined}"

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
    organisation.set(feedback_summary: last_paragraph)
    organisation.set(feedback_summary_last_refreshed_at: Time.now)
  end
end
