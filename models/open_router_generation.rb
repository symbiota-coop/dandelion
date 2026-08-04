class OpenRouterGeneration
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :prompt, type: String
  field :response, type: String
  field :model, type: String
  field :source, type: String

  validates_presence_of :response
end
