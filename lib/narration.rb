class Narration
  def self.extract(file)
    content = File.read(file)
    # Use a regex to match 'narrate %(...)' blocks, including multi-line content
    narration = content.scan(/narrate\s+%\((.*?)\)/m).flatten
    narration.join("\n")
  end
end
