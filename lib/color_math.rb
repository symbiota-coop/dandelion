# Conversions between hex, RGB and HSL, and the WCAG contrast ratio, for theme colours. Hues are in degrees, and
# saturation and lightness from 0 to 1
module ColorMath
  HEX = /\A#?(\h{3}|\h{6})\z/

  # [r, g, b] from 0 to 255, from #rgb or #rrggbb
  def self.rgb(hex)
    digits = hex[HEX, 1] or raise ArgumentError, "not a hex colour: #{hex.inspect}"
    digits = digits.chars.map { |c| c * 2 }.join if digits.length == 3
    digits.scan(/../).map(&:hex)
  end

  def self.hex(rgb)
    "##{rgb.map { |c| c.round.to_s(16).rjust(2, '0') }.join}"
  end

  # [h, s, l]
  def self.hsl(hex)
    r, g, b = rgb(hex).map { |c| c / 255.0 }
    max, min = [r, g, b].minmax.reverse
    l = (max + min) / 2
    return [0, 0, l] if max == min

    d = max - min
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
    h = case max
        when r then ((g - b) / d) + (g < b ? 6 : 0)
        when g then ((b - r) / d) + 2
        else ((r - g) / d) + 4
        end
    [h * 60, s, l]
  end

  def self.hsl_to_hex(h, s, l)
    return hex([l * 255] * 3) if s.zero?

    q = l < 0.5 ? l * (1 + s) : l + s - (l * s)
    p = (2 * l) - q
    h = (h % 360) / 360.0
    hex([h + (1 / 3.0), h, h - (1 / 3.0)].map { |t| hue_to_channel(p, q, t) * 255 })
  end

  def self.hue_to_channel(p, q, t)
    t += 1 if t.negative?
    t -= 1 if t > 1
    if t < 1 / 6.0 then p + ((q - p) * 6 * t)
    elsif t < 0.5 then q
    elsif t < 2 / 3.0 then p + ((q - p) * ((2 / 3.0) - t) * 6)
    else p
    end
  end

  # The colour with its lightness lowered by amount (0 to 1)
  def self.darken(hex, amount)
    h, s, l = hsl(hex)
    hsl_to_hex(h, s, (l - amount).clamp(0, 1))
  end

  # The WCAG contrast ratio of two colours, from 1 to 21
  def self.contrast(hex1, hex2)
    lighter, darker = [hex1, hex2].map { |c| luminance(c) }.sort.reverse
    (lighter + 0.05) / (darker + 0.05)
  end

  def self.luminance(hex)
    r, g, b = rgb(hex).map do |c|
      c /= 255.0
      c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
    end
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end
end
