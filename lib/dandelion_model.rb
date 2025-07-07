class DandelionModel
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  def self.inherited(subclass)
    super
    subclass.store_in(collection: subclass.name.tableize)
  end
end
