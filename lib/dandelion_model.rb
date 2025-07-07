class DandelionModel
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation
end
