class Nft
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :nft_collection, index: true
  belongs_to :account, index: true

  field :image_url, type: String

  def self.admin_fields
    {
      image_url: :url,
      account_id: :lookup,
      nft_collection_id: :lookup
    }
  end

  after_create :generate_nft

  def generate_nft
    headers = {
      Authorization: "Bearer #{ENV['NEXTLEG_API_KEY']}",
      'Content-Type': 'application/json'
    }

    r = Faraday.post('https://api.thenextleg.io/v2/imagine', { msg: nft_collection.prompt }.to_json, headers)
    message_id = JSON.parse(r.body)['messageId']

    progress = 0
    until progress == 100
      begin
      sleep 1
      r = Faraday.get("https://api.thenextleg.io/v2/message/#{message_id}", {}, headers)
      j = JSON.parse(r.body)
      puts j
      progress = j['progress'].to_i
      rescue StandardError; end
    end

    # image_url = j['response']['imageUrl']
    # image = MiniMagick::Image.open(j['response']['imageUrl'])
    # image.crop('1024x1024+0+0')
    # image.write('cropped_image.png')

    r = Faraday.post('https://api.thenextleg.io/v2/button', { buttonMessageId: j['response']['buttonMessageId'], button: 'U1' }.to_json, headers)
    message_id = JSON.parse(r.body)['messageId']

    progress = 0
    until progress == 100
      begin
      sleep 1
      r = Faraday.get("https://api.thenextleg.io/v2/message/#{message_id}", {}, headers)
      j = JSON.parse(r.body)
      puts j
      progress = j['progress'].to_i
      rescue StandardError; end
    end

    update_attribute(:image_url, j['response']['imageUrl'])

    send_nft
  end

  def send_nft
    headers = {
      'x-client-secret' => ENV['CROSSMINT_CLIENT_SECRET'],
      'x-project-id' => ENV['CROSSMINT_PROJECT_ID'],
      'Content-Type' => 'application/json'
    }
    data = {
      metadata: {
        name: "#{nft_collection.name} ##{nft_collection.nfts.order('created_at asc').pluck(:id).index(id) + 1}",
        image: image_url,
        description: ''
      },
      recipient: "email:#{account.email}:polygon"
    }
    Faraday.post("https://www.crossmint.com/api/2022-06-09/collections/#{nft_collection.crossmint_id}/nfts", data.to_json, headers)
  end
end
