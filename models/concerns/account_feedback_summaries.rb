module AccountFeedbackSummaries
  extend ActiveSupport::Concern

  class_methods do
    def set_feedback_summaries
      # Account.and(:feedback_summary.ne => nil).set(feedback_summary: nil)
      accounts = Account.and(:id.in => EventFacilitation.and(:event_id.in => Event.past.pluck(:id)).pluck(:account_id))
      accounts = accounts.select { |account| account.feedback_summary.nil? && account.event_feedbacks_as_facilitator.count >= 10 }
      accounts.each_with_index do |account, i|
        puts "#{i + 1}/#{accounts.count} #{account.username}"

        summary = account.event_feedbacks_as_facilitator.order('created_at desc').and(:answers.ne => nil).map { |ef| "# Feedback on #{ef.event.name}, #{ef.event.start_time}\n\n#{ef.answers.join("\n")}" }.join("\n\n")
        prompt = "Provide a one-paragraph summary of the feedback on this facilitator, #{account.firstname}. Focus on their strengths and what they do well. \n\n#{summary}"

        prompt = prompt[0..(200_000 * 0.66 * 4)]
        client = Anthropic::Client.new
        last_paragraph = nil
        loop do
          response = client.messages(
            parameters: {
              model: 'claude-3-haiku-20240307',
              messages: [
                { role: 'user', content: prompt }
              ],
              max_tokens: 256
            }
          )
          if response['content']
            paragraphs = response['content'].first['text'].split("\n\n")
            if paragraphs.length <= 2
              last_paragraph = paragraphs.last
              break if last_paragraph.split.length >= 50 && last_paragraph[0] != '-' && last_paragraph[0] != '*' && last_paragraph[-1] == '.'
            end
          else
            puts 'sleeping...'
            sleep 5
          end
        end
        puts "#{last_paragraph}\n\n"
        account.set(feedback_summary: last_paragraph)
      end

      # accounts.each(&:send_feedback_summary)
    end
  end
end
