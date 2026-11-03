# Custom cops, each explaining its rule in its doc comment. Loaded by .rubocop.yml, which sets them to warning so they fail CI
Dir[File.join(__dir__, 'dandelion', '*.rb')].each { |f| require f }
