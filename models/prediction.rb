class Prediction
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  belongs_to :account, optional: true, index: true

  field :prompt, type: String
  field :replicate_id, type: String
  field :result, type: Hash
  field :favs, type: Array

  def self.admin_fields
    {
      prompt: :text,
      replicate_id: { type: :text, disabled: true },
      result: { type: :text_area, disabled: true },
      favs: { type: :text_area, disabled: true },
      account_id: :lookup
    }
  end

  has_many :posts, as: :commentable, dependent: :destroy
  has_many :subscriptions, as: :commentable, dependent: :destroy
  has_many :comments, as: :commentable, dependent: :destroy
  has_many :comment_reactions, as: :commentable, dependent: :destroy

  validates_presence_of :prompt, :replicate_id

  before_validation do
    unless replicate_id
      version = 'a9758cbfbd5f3c2094457d996681af52552901775aa2d6dd0b17fd15df959bef'
      width = 512
      height = 512
      r = Prediction.api.post('predictions') do |req|
        req.body = { version: version, input: { num_outputs: 4, width: width, height: height, prompt: prompt } }.to_json
      end
      self.replicate_id = JSON.parse(r.body)['id']
    end
  end

  def fetch!
    r = Prediction.api.get("predictions/#{replicate_id}")
    self.result = JSON.parse(r.body)
    save
  end

  def finished?
    result && (result['error'] || result['output'])
  end

  def self.api
    Faraday.new(
      url: 'https://api.replicate.com/v1',
      headers: { 'Authorization': "Token #{ENV['REPLICATE_API_KEY']}", 'Content-Type': 'application/json' }
    )
  end
end
