MESSAGES_TO_IGNORE = [
  'Ticket type is full',
  'No such charge',
  'No such transfer'
].freeze

Honeybadger.configure do |config|
  config.before_notify do |notice|
    notice.halt! if MESSAGES_TO_IGNORE.any? { |message| notice.error_message.include?(message) }
  end
end
