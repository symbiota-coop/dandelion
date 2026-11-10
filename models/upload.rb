class Upload
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include RejectsActiveContent

  extend Dragonfly::Model

  belongs_to_without_parent_validation :account

  field :file_name, type: String
  field :file_uid, type: String

  dragonfly_accessor :file do
    after_assign do |attachment|
      # Other files are kept as they are, never run through ImageMagick (image? runs identify)
      if ImageSignature.allowed?(attachment) && attachment.image?
        if attachment.format != 'jpeg'
          attachment.convert('-format jpeg')
          attachment.name = "#{SecureRandom.uuid}.jpeg"
        end

        attachment.process!(:thumb, '1920x1920>')
      end
    end
  end

  def summary
    file_name
  end
end

