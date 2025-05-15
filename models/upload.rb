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

  dragonfly_accessor :file do
    after_assign do |attachment|
      if attachment.image?
        if attachment.format == 'heic'
          attachment.convert('-format jpeg')
          attachment.name = "#{SecureRandom.uuid}.jpg"
        end

        attachment.process!(:thumb, '1920x1920>')
      end
    end
  end
end
