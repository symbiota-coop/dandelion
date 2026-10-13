# Custom cops that check rules from AGENTS.md. Loaded by .rubocop.yml, which sets them to warning so they fail CI
Dir[File.join(__dir__, 'dandelion', '*.rb')].each { |f| require f }
