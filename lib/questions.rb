module Questions
  SELECT_FIELD_REGEX = /^(.+?)\s*<\s*(.+?)\s*>\*?$/
  MULTIPLE_CHECKBOX_FIELD_REGEX = /^(.+?)\s*\[\s*(.+?)\s*\]\*?$/
  CHECKBOX_FIELD_REGEX = /^\s*\[(.+?)\]\s*\*?$/
  DATE_FIELD_REGEX = /^\s*\{(.+?)\}\s*\*?$/

  FIELD_REGEXES = [
    SELECT_FIELD_REGEX,
    MULTIPLE_CHECKBOX_FIELD_REGEX,
    CHECKBOX_FIELD_REGEX,
    DATE_FIELD_REGEX
  ].freeze

  def self.extract_question_text(question)
    FIELD_REGEXES.inject(nil) { |result, regex| result || question.match(regex)&.[](1) } || question
  end

  # Describes each line of a questions string as questions/_questions.erb renders it.
  # index is the line's position, the key its answer takes in answers[index].
  def self.parse(questions)
    lines = questions.to_s.split("\n").map(&:strip).reject(&:blank?)
    lines.each_with_index.map do |q, i|
      required = q.ends_with?('*')
      field = if (m = q.match(/^#\s*(.+)/))
                { type: 'heading', text: m[1] }
              elsif (m = q.match(/^-\s*(.+)/))
                { type: 'info', text: m[1].chomp('*') }
              elsif (m = q.match(SELECT_FIELD_REGEX))
                { type: 'select', text: m[1].chomp('*'), options: m[2].split(',').map(&:strip), required: required }
              elsif (m = q.match(MULTIPLE_CHECKBOX_FIELD_REGEX))
                { type: 'checkboxes', text: m[1], options: m[2].split(',').map(&:strip), required: required }
              elsif (m = q.match(CHECKBOX_FIELD_REGEX))
                { type: 'checkbox', text: m[1], required: required }
              elsif (m = q.match(DATE_FIELD_REGEX))
                { type: 'date', text: m[1], required: required }
              else
                { type: 'text', text: q.chomp('*'), required: required }
              end
      { index: i, question: q }.merge(field)
    end
  end

  # answers: keyed by question index, as questions/_questions.erb sends them (a ticked checkbox as '1', checkboxes as
  # a hash of the ticked options), or as true/false and an array of options.
  # Returns the [question, answer] pairs orders store, with the questions' own text, or an error saying which answers
  # are wrong: to questions there aren't, options there aren't, or required questions left unanswered
  def self.answer_pairs(questions, answers)
    answers = (answers || {}).to_h.transform_keys(&:to_s)
    fields = parse(questions).reject { |field| %w[heading info].include?(field[:type]) }
    unknown = answers.keys - fields.map { |field| field[:index].to_s }
    return [nil, "Unknown question indexes: #{unknown.join(', ')}"] if unknown.any?

    invalid = fields.select do |field|
      answer = answers[field[:index].to_s].to_s.strip
      field[:type] == 'select' && !answer.empty? && !field[:options].include?(answer)
    end
    return [nil, "Choose one of the options: #{invalid.map { |field| "#{field[:text]} (#{field[:options].join(', ')})" }.join('; ')}"] if invalid.any?

    pairs = fields.map do |field|
      value = answers[field[:index].to_s]
      value = case field[:type]
              when 'checkbox' then ('1' if [true, 'true', '1'].include?(value))
              when 'checkboxes'
                selected = (value.is_a?(Hash) ? value.values : Array(value)).map(&:to_s) & field[:options]
                selected unless selected.empty?
              else
                value.to_s.strip unless value.to_s.strip.empty?
              end
      [field, [field[:question], value]]
    end

    missing = pairs.select { |field, (_question, value)| field[:required] && value.nil? }.map { |field, _pair| field[:text] }
    return [nil, "Answer the required questions: #{missing.join('; ')}"] if missing.any?

    # As the checkout form sends them: an unticked checkbox, or checkboxes with none ticked, not at all
    [pairs.reject { |field, (_question, value)| %w[checkbox checkboxes].include?(field[:type]) && value.nil? }.map(&:last), nil]
  end
end
