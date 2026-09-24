require 'securerandom'

# Two-word usernames. No external gem.
module HaikuName
  ADJECTIVES = %w[
    amber bold bright calm clear cool dark early fair gentle
    golden green hidden icy kind late little lively lonely
    lucky mild misty northern old patient quiet rapid red
    silent silver small soft still swift warm wild young
  ].freeze

  NOUNS = %w[
    brook cedar cloud creek dawn field frost garden grove harbor
    hazel heron hill lake leaf meadow moon orchard pine pond
    rain river robin sky star stone stream summit thistle valley
    willow wind
  ].freeze

  def self.generate
    "#{ADJECTIVES[SecureRandom.random_number(ADJECTIVES.length)]}_#{NOUNS[SecureRandom.random_number(NOUNS.length)]}"
  end
end
