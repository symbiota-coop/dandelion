class Provider
  @@all = []

  attr_accessor :display_name, :omniauth_name, :icon, :nickname, :profile_url, :image

  def initialize(display_name, options = {})
    @display_name = display_name
    @omniauth_name = options[:omniauth_name] || display_name.downcase
    @icon = options[:icon] || display_name.downcase
    @nickname = options[:nickname] || ->(hash) { hash['info']['nickname'] }
    @profile_url = options[:profile_url] || ->(hash) { "https://#{hash['provider']}.com/#{hash['info']['nickname']}" }
    @image = options[:image] || ->(hash) { hash['info']['image'] }
    @@all << self
  end

  def self.all
    @@all
  end

  def self.object(omniauth_name)
    all.find { |provider| provider.omniauth_name == omniauth_name }
  end
end

Provider.new('Ethereum', icon: 'fab fa-ethereum')
