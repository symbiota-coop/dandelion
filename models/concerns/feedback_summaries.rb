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
    true
  end

  # Generating a summary can take up to MAX_ATTEMPTS model calls, so the refresh links queue it and the summary's
  # pagelet refreshes itself until it's done
  def request_feedback_summary!
    return if feedback_summary_generating?

    set(feedback_summary_requested_at: Time.now, feedback_summary_failed_at: nil)
    delay.generate_requested_feedback_summary
  end

  # A request older than the worker's max_run_time is a job that died, so stop showing it as generating
  def feedback_summary_generating?
    feedback_summary_requested_at && feedback_summary_requested_at > Delayed::Worker.max_run_time.ago
  end

  def generate_requested_feedback_summary
    generated = begin
      feedback_summary!
    rescue StandardError => e
      ErrorReporting.capture_exception(e, context: { model: self.class.name, id: id.to_s })
      nil
    end
    set(feedback_summary_requested_at: nil, feedback_summary_failed_at: (Time.now unless generated))
  end

  # The model sometimes adds inline markdown (**bold**, *titles*); the summary is one paragraph, rendered inline
  def feedback_summary_html
    return unless feedback_summary

    MarkdownRenderer.render(feedback_summary, inline: true)
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
