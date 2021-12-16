class Upload
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :account, index: true

  field :file_name, type: String
  field :file_uid, type: String

  def self.admin_fields
    {
      file_name: { type: :text, edit: false },
      file: :file,
      account_id: :lookup
    }
  end

  # Dragonfly
  dragonfly_accessor :file
end
