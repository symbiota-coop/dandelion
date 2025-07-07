class DandelionModel
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  self.abstract_class = true
end
