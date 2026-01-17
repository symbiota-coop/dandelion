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
end
