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
end
