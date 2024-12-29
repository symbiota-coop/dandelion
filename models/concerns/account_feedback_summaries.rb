module AccountFeedbackSummaries
  extend ActiveSupport::Concern

  class_methods do
    def set_feedback_summaries
      # Account.and(:feedback_summary.ne => nil).set(feedback_summary: nil)
      accounts = Account.and(:id.in => EventFacilitation.and(:event_id.in => Event.past.pluck(:id)).pluck(:account_id))
      accounts = accounts.select { |account| account.feedback_summary.nil? && account.event_feedbacks_as_facilitator.count >= 10 }
      accounts.each_with_index do |account, i|
        puts "#{i + 1}/#{accounts.count} #{account.username}"
        account.feedback_summary!
      end

      # accounts.each(&:send_feedback_summary)
    end
  end

  def feedbacks_joined
    event_feedbacks_as_facilitator.order('created_at desc').and(:answers.ne => nil).map do |ef|
      next unless ef.event

      "# Feedback on #{ef.event.name}, #{ef.event.start_time}\n\n#{ef.answers.map { |q, a| "## #{q}\n#{a}" }.join("\n\n")}"
    end.compact.join("\n\n")
  end

  def feedback_summary!
    account = self
    prompt = "Provide a one-paragraph summary of the feedback on this facilitator, #{account.firstname}. Focus on their strengths and what they do well. \n\n#{feedbacks_joined}"

    last_paragraph = nil
    loop do
      response = OpenRouter.chat(prompt, max_tokens: 256)
      paragraphs = response.split("\n\n")
      if paragraphs.length <= 2
        last_paragraph = paragraphs.last
        break if last_paragraph.split.length >= 50 && last_paragraph[0] != '-' && last_paragraph[0] != '*' && last_paragraph[-1] == '.'
      end
    end
    # sentences = last_paragraph.split('. ')
    # last_paragraph = sentences[1..-1].join('. ') if sentences[0] =~ /The feedback .* positive/ || sentences[0] =~ /positive feedback/
    puts "#{last_paragraph}\n\n"
    account.set(feedback_summary: last_paragraph)
  end
end
