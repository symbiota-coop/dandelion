# An account's avatar: its image, its Gravatar, or with neither a generated one: their initials in Plus Jakarta Sans, as
# a stencil that takes the page's theme colour from the <img>'s background (.avatar-initials, Account#avatar_class):
# the letters are cut out, so the theme shows through them, and the rest is white at WASH, so it shows through paler,
# close to --theme-100
module AccountAvatar
  extend ActiveSupport::Concern

  WASH = 0.8

  FONT = Padrino.root('app/assets/fonts/PlusJakartaSans/ttf/PlusJakartaSans-SemiBold.ttf')
  SIZE = 400

  # One or two letters the font has: Latin letters, with any accents
  INITIALS = /\A(\p{Latin}\p{M}*){1,2}\z/

  class_methods do
    # The first letters of the first and last words of a name, skipping a title; nil if they aren't Latin letters
    def avatar_initials(name)
      words = name.to_s.unicode_normalize(:nfc).split.reject { |w| %w[mr mrs ms dr].include?(w.downcase.delete('.')) }
      initials = [words.first, (words.last if words.length > 1)].compact.map { |w| w.grapheme_clusters.first }.join.upcase
      initials if initials.match?(INITIALS)
    end

    # White, opaque at WASH, with the letters clear, drawn by libvips (Pango) and centred by their ink
    def avatar_png(initials = nil)
      alpha = Vips::Image.black(SIZE, SIZE) + (WASH * 255).round
      if initials
        size = initials.length > 1 ? 150 : 180
        # How much of each pixel the letters cover, 0 to 255; at 72 dpi, a point is a pixel
        letters = Vips::Image.text(initials, fontfile: FONT.to_s, font: "Plus Jakarta Sans SemiBold #{size}", dpi: 72)
        letters = letters.embed((SIZE - letters.width) / 2, (SIZE - letters.height) / 2, SIZE, SIZE)
        alpha *= (letters * (-1.0 / 255)) + 1
      end
      (Vips::Image.black(SIZE, SIZE, bands: 3) + 255).bandjoin(alpha).cast(:uchar).copy(interpretation: :srgb)
                                                     .write_to_buffer('.png')
    end
  end

  def image_thumb_or_gravatar_url
    if image
      begin
        image.thumb('400x400#').url
      rescue StandardError, Dragonfly::Shell::CommandFailed
        gravatar_url
      end
    else
      gravatar_url
    end
  end

  def gravatar_url
    # Addressable leaves the fallback's : and / alone, as views escape this URL again with u (so % would become %25)
    Padrino.env == :development ? generated_avatar_path : "https://www.gravatar.com/avatar/#{Digest::MD5.hexdigest(email.downcase)}?s=400&d=#{Addressable::URI.escape("#{ENV['BASE_URI']}#{generated_avatar_path}")}"
  end

  # For the <img> of an account's image or Gravatar: the generated avatar is a stencil (avatar_png),
  # which takes the theme colour from avatar-initials' background. Photos are opaque, so it doesn't show behind them
  def avatar_class
    'avatar-initials' unless image
  end

  # Unescaped (an accented initial stays as it is), as gravatar_url and the views escape it
  def generated_avatar_path
    initials = self.class.avatar_initials(name)
    initials ? "/avatar/v2/#{initials}.png" : '/avatar/v2.png'
  end
end
