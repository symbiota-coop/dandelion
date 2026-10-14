# Avatars for accounts with no image: their initials in Plus Jakarta Sans, as a stencil that takes the page's theme
# colour from the <img>'s background (.avatar-initials, Account#avatar_class): the letters are cut out, so the theme
# shows through them, and the rest is white at WASH, so it shows through paler, close to --theme-100
module GeneratedAvatar
  WASH = 0.8

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
        c << 'xc:white'
        # The alpha: the letters in black (clear) on grey at WASH
        c.stack do |mask|
          mask.size "#{SIZE}x#{SIZE}"
          mask << "xc:gray(#{(WASH * 100).round}%)"
          if initials
            mask.font FONT
            mask.fill 'black'
            mask.pointsize(initials.length > 1 ? 150 : 180)
            mask.gravity 'center'
            mask.annotate '+0+0', initials
          end
        end
        c.alpha 'off'
        c.compose 'CopyOpacity'
        c.composite
        c << file.path
      end
      File.binread(file.path)
    end
  end
end
