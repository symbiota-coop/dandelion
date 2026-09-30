module AppModels
  # Every model in models/, as classes
  def self.all
    Dir.glob(Padrino.root('models', '*.rb')).map { |file| File.basename(file, '.rb').camelize.constantize }
  end
end
