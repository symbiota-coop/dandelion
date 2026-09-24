# Hex, HSL, and contrast for theme colours. No external gem.
module ColorMath
  Hsl = Struct.new(:h, :s, :l)

  def self.hsl(hex)
    r, g, b = rgb(hex).map { |n| n / 255.0 }
    max = [r, g, b].max
    min = [r, g, b].min
    lightness = (max + min) * 0.5
    if max == min
      hue = saturation = 0.0
    else
      delta = max - min
      saturation = lightness > 0.5 ? delta / (2 - max - min) : delta / (max + min)
      hue = case max
            when r then (g - b) / delta + (g < b ? 6 : 0)
            when g then (b - r) / delta + 2
            when b then (r - g) / delta + 4
            end
      hue /= 6.0
    end
    Hsl.new(hue * 360, saturation, lightness)
  end

  def self.hex_from_hsl(hue, saturation_percent, lightness_percent)
    h = (hue.to_f % 360) / 360.0
    s = [[saturation_percent.to_f, 0].max, 100].min / 100.0
    l = [[lightness_percent.to_f, 0].max, 100].min / 100.0
    if s.zero?
      r = g = b = l * 255
    else
      q = l < 0.5 ? l * (1 + s) : l + s - (l * s)
      p = (2 * l) - q
      r = hue_to_rgb(p, q, h + (1 / 3.0)) * 255
      g = hue_to_rgb(p, q, h) * 255
      b = hue_to_rgb(p, q, h - (1 / 3.0)) * 255
    end
    format('#%02x%02x%02x', r.round, g.round, b.round)
  end

  def self.contrast_ratio(hex_a, hex_b)
    darker, lighter = [relative_luminance(hex_a), relative_luminance(hex_b)].sort
    (lighter + 0.05) / (darker + 0.05)
  end

  def self.rgb(hex)
    chars = hex.to_s.delete('#')
    chars = chars.chars.map { |c| c * 2 }.join if chars.length == 3
    [chars[0, 2], chars[2, 2], chars[4, 2]].map { |pair| pair.to_i(16) }
  end

  def self.relative_luminance(hex)
    r, g, b = rgb(hex)
    (0.2126 * linear_channel(r)) + (0.7152 * linear_channel(g)) + (0.0722 * linear_channel(b))
  end

  def self.linear_channel(component)
    c = component / 255.0
    c <= 0.03928 ? c : ((c + 0.055) / 1.055)**2.4
  end

  def self.hue_to_rgb(p, q, t)
    t += 1 if t.negative?
    t -= 1 if t > 1
    return p + ((q - p) * 6 * t) if t < 1 / 6.0
    return q if t < 0.5
    return p + ((q - p) * ((2 / 3.0) - t) * 6) if t < 2 / 3.0

    p
  end
  private_class_method :hue_to_rgb, :linear_channel
end
