module AccountFeedbackSummaries
  extend ActiveSupport::Concern

  class_methods do
    def set_feedback_summaries
      # Account.and(:feedback_summary.ne => nil).update_all(feedback_summary: nil)
      accounts = Account.and(:id.in => EventFacilitation.and(:event_id.in => Event.past.pluck(:id)).pluck(:account_id), :feedback_summary => nil)
      accounts = accounts.select { |account| account.event_feedbacks_as_facilitator.count >= 10 }
      accounts.each_with_index do |account, i|
        puts "#{i + 1}/#{accounts.count} #{account.username}"
        account.feedback_summary!
      end

      # accounts.each { |account| account.send_feedback_summary if account.feedback_summary }
    end
  end

  def feedback_summary!
    account = self
    prompt = "Provide a one-paragraph summary of the feedback on this facilitator, #{account.name}. Focus on their strengths and what they do well. The feedback:\n\n#{account.event_feedbacks_as_facilitator.joined}"

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
    # sentences = last_paragraph.split('. ')
    # last_paragraph = sentences[1..-1].join('. ') if sentences[0] =~ /The feedback .* positive/ || sentences[0] =~ /positive feedback/
    puts "#{last_paragraph}\n\n"
    account.set(feedback_summary: last_paragraph)
    account.set(feedback_summary_last_refreshed_at: Time.now)
  end
end
