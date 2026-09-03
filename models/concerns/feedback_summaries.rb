module FeedbackSummaries
  extend ActiveSupport::Concern

  MAX_ATTEMPTS = 10
  MIN_FEEDBACKS = 10

  class_methods do
    def set_feedback_summaries
      records = feedback_summaries_scope.and(feedback_summary: nil, feedback_summary_last_refreshed_at: nil)
      records = records.select { |record| record.feedback_summaries_source.count >= MIN_FEEDBACKS }
      records.each_with_index do |record, i|
        puts "#{i + 1}/#{records.count} #{record.feedback_summary_log_label}"
        record.feedback_summary!
      end
    end
  end

  def feedback_summary!
    last_paragraph = feedback_summary_paragraph
    return unless last_paragraph

    puts "#{last_paragraph}\n\n"
    set(feedback_summary: last_paragraph, feedback_summary_last_refreshed_at: Time.now)
  end

  private

  def feedback_summary_paragraph
    last_paragraph = nil
    MAX_ATTEMPTS.times do
      response = OpenRouter.chat(feedback_summary_prompt)
      next if response.blank?

      paragraphs = response.split("\n\n")
      next if paragraphs.length > 2

      candidate = paragraphs.last.strip
      next unless candidate.split.length >= 50 && candidate[0] != '-' && candidate[0] != '*' && candidate[-1] == '.'

      last_paragraph = candidate
      break
    end
    return unless last_paragraph

    sentences = last_paragraph.split('. ')
    last_paragraph = sentences[1..-1].join('. ') if sentences[0] =~ /The feedback .* positive/ || sentences[0] =~ /positive feedback/
    last_paragraph
  end
end
