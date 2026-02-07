class Upload
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model

  belongs_to_without_parent_validation :account

  field :file_name, type: String
  field :file_uid, type: String

  def self.admin_fields
    {
      file_name: { type: :text, edit: false },
      file: :file,
      account_id: :lookup
    }
  end

  dragonfly_accessor :file do
    after_assign do |attachment|
      if attachment.image?
        if attachment.format != 'jpeg'
          attachment.convert('-format jpeg')
          attachment.name = "#{SecureRandom.uuid}.jpeg"
        end

        attachment.process!(:thumb, '1920x1920>')
      end
    end
  end
end
