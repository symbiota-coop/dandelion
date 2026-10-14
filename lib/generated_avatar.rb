# Avatars for accounts with no image: their initials in Plus Jakarta Sans, in --color-lavender-500 on --color-lavender-100
module GeneratedAvatar
  # As hex, since ImageMagick can't read the oklch() they're defined with in app.css
  BACKGROUND = '#ede1ff'.freeze # --color-lavender-100
  TEXT = '#a376e9'.freeze # --color-lavender-500

  FONT = Padrino.root('app/assets/fonts/PlusJakartaSans/ttf/PlusJakartaSans-SemiBold.ttf')
  SIZE = 400

  # One or two letters the font has: Latin letters, with any accents
  INITIALS = /\A(\p{Latin}\p{M}*){1,2}\z/

  # The first letters of the first and last words of a name, skipping a title; nil if they aren't Latin letters
  def self.initials(name)
    words = name.to_s.unicode_normalize(:nfc).split.reject { |w| %w[mr mrs ms dr].include?(w.downcase.delete('.')) }
    initials = [words.first, (words.last if words.length > 1)].compact.map { |w| w.grapheme_clusters.first }.join.upcase
    initials if initials.match?(INITIALS)
  end

  def self.png(initials = nil)
    Tempfile.create(['avatar', '.png']) do |file|
      MiniMagick.convert do |c|
        c.size "#{SIZE}x#{SIZE}"
        c << "xc:#{BACKGROUND}"
        if initials
          c.font FONT
          c.fill TEXT
          c.pointsize(initials.length > 1 ? 150 : 180)
          c.gravity 'center'
          c.annotate '+0+0', initials
        end
        c << file.path
      end
      File.binread(file.path)
    end
  end
end
