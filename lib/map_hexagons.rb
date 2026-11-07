# Maps show accounts at about their neighbourhood, not where they are: in a grid of hexagons, SIZE across from their
# centre to a corner (about 1 km in London), each account at the centre of the hexagon it's in.
# The grid is laid out on the map as Google draws it (Web Mercator), so the hexagons look regular there; its units are
# degrees of longitude, so they cover less ground away from the equator, as the map does. Hexagon (q, r) is in axial
# coordinates (https://www.redblobgames.com/grids/hexagons/), with its corners pointing up and down. An account stores
# its smallest hexagon as map_hex ("q,r"), so maps count accounts by it without reading where they are
module MapHexagons
  # The smallest hexagons, in degrees of longitude from a hexagon's centre to a corner. Accounts store theirs (map_hex),
  # so after changing it, set every account's map_hex again
  SIZE = 0.015
  # How wide hexagons on a map are on screen, at least, in pixels: up to twice this, as they grow a doubling at a time
  PIXELS = 80

  module_function

  def mercator_y(lat)
    lat = lat.to_f.clamp(-85, 85) * Math::PI / 180
    Math.log(Math.tan((Math::PI / 4) + (lat / 2))) * 180 / Math::PI
  end

  def mercator_lat(y)
    ((2 * Math.atan(Math.exp(y * Math::PI / 180))) - (Math::PI / 2)) * 180 / Math::PI
  end

  # The hexagon of the given size a point is in, [q, r]
  def hex(lng, lat, size)
    x = lng.to_f
    y = mercator_y(lat)
    q = ((Math.sqrt(3) / 3 * x) - (y / 3)) / size
    r = (2.0 / 3 * y) / size
    # Round to the nearest hexagon in cube coordinates, where q + r + s = 0, fixing whichever rounded furthest
    s = -q - r
    rq, rr, rs = [q, r, s].map(&:round)
    if (rq - q).abs > (rr - r).abs && (rq - q).abs > (rs - s).abs
      rq = -rr - rs
    elsif (rr - r).abs > (rs - s).abs
      rr = -rq - rs
    end
    [rq, rr]
  end

  # A point in hexagon (q, r), dx and dy from its centre in the grid's units, as [lng, lat]
  def point(hex, size, dx = 0, dy = 0)
    q, r = hex
    x = (size * Math.sqrt(3) * (q + (r / 2.0))) + dx
    y = (size * 1.5 * r) + dy
    [x.round(6), mercator_lat(y).round(6)]
  end

  # The corners of hexagon (q, r), as [lat, lng]s
  def corners(hex, size)
    (0..5).map do |i|
      angle = ((60 * i) - 30) * Math::PI / 180
      lng, lat = point(hex, size, size * Math.cos(angle), size * Math.sin(angle))
      [lat, lng]
    end
  end

  # The smallest hexagon [lng, lat] is in, as an account stores it in map_hex
  def key(coordinates)
    coordinates && hex(*coordinates, SIZE).join(',')
  end

  def from_key(key)
    key.split(',').map(&:to_i)
  end
end
