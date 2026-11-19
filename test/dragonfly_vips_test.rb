require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'vips'

# The libvips plugin for Dragonfly (lib/dragonfly_vips.rb), on an app of its own, as Dragonfly.app still runs
# ImageMagick: it takes the ImageMagick plugin's arguments and gives its answers, so derivative URLs keep working
class DragonflyVipsTest < ActiveSupport::TestCase
  def app
    @app ||= Dragonfly.app(:vips_test).tap { |app| app.configure { plugin DragonflyVips::Plugin.new } }
  end

  # A width by height image in the format the suffix names, as libvips writes it; alpha: for a transparent one
  def image(width, height, suffix, alpha: false, **)
    pixels = (Vips::Image.black(width, height) + [200, 40, 40])
    pixels = pixels.bandjoin(0) if alpha
    app.create(pixels.cast(:uchar).copy(interpretation: :srgb).write_to_buffer(suffix, **), 'name' => "image#{suffix}")
  end

  def vips(job)
    Vips::Image.new_from_buffer(job.apply.data, '')
  end

  test 'analyses JPEGs, PNGs, GIFs and WebPs as ImageMagick names them' do
    { '.jpg' => 'jpeg', '.png' => 'png', '.gif' => 'gif', '.webp' => 'webp' }.each do |suffix, format|
      job = image(30, 20, suffix)

      assert_equal [format, 30, 20, true], [job.format, job.width, job.height, job.image?]
      assert_equal true, job.landscape?
    end
  end

  test 'measures a photo as it is shown, after its EXIF orientation, and turns its pixels to match' do
    pixels = (Vips::Image.black(30, 20) + 100).cast(:uchar).copy
    pixels.set_type(GObject::GINT_TYPE, 'orientation', 6)
    job = app.create(pixels.write_to_buffer('.jpg'), 'name' => 'photo.jpg')

    assert_equal [20, 30], [job.width, job.height]
    thumb = vips(job.thumb('400x400'))
    assert_equal [267, 400], [thumb.width, thumb.height]
  end

  test 'refuses SVG, PDF and other files libvips could read but we do not take' do
    svg = app.create('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>')
    tiff = app.create((Vips::Image.black(10, 10) + 1).cast(:uchar).write_to_buffer('.tif'))

    [svg, tiff].each do |job|
      assert_equal false, job.image?
      assert_raises(Vips::Error, DragonflyVips::UnsupportedFormat) { job.thumb('10x10').apply }
    end
    assert_equal true, image(10, 10, '.png').image?
  end

  test 'thumb fits, shrinks only, and fills and crops, as ImageMagick does for our geometry strings' do
    job = image(800, 400, '.jpg')

    { '400x400' => [400, 200], '1920x1920>' => [800, 400], '500x500#' => [500, 500], '1200x630' => [1200, 600],
      'x100' => [200, 100], '200x' => [200, 100], '1000x1000<' => [1000, 500] }.each do |geometry, size|
      thumb = vips(job.thumb(geometry))
      assert_equal size, [thumb.width, thumb.height], geometry
    end
    assert_raises(ArgumentError) { job.thumb('400x400+10+10').apply }
    assert_raises(ArgumentError) { job.thumb('x').apply }
  end

  test 'thumb keeps the format of the image, whatever its name says, or writes the one asked for, as uploads do' do
    png = image(100, 100, '.png')
    png.name = 'upload.jpeg'
    assert_equal 'pngload_buffer', vips(png.thumb('50x50')).get('vips-loader')

    jpeg = png.thumb('1920x1920>', 'format' => 'jpeg').apply
    assert_equal ['jpeg', 'jpeg'], [jpeg.format, jpeg.ext]
    assert_equal 'jpegload_buffer', vips(jpeg).get('vips-loader')
  end

  test 'encode writes the format at the quality given, and the thumb after it keeps that format' do
    png = image(1000, 500, '.png', alpha: true)
    og = png.encode('jpg', '-quality 90').thumb('1200x630')

    assert_equal 'jpeg', og.apply.format
    jpeg = vips(og)
    assert_equal [1200, 600, 3], [jpeg.width, jpeg.height, jpeg.bands]
    # Transparent pixels go white rather than black
    assert_equal [255, 255, 255], jpeg.getpoint(10, 10).map(&:round)

    noise = app.create(Vips::Image.gaussnoise(200, 200).cast(:uchar).write_to_buffer('.png'), 'name' => 'noise.png')
    assert_operator noise.encode('jpg', '-quality 10').apply.size * 2, :<, noise.encode('jpg', '-quality 95').apply.size
  end

  test 'encode refuses ImageMagick arguments other than -quality' do
    job = image(10, 10, '.png')

    ['-density 300', '-quality 90 -write /tmp/x.png', '-quality'].each do |args|
      assert_raises(ArgumentError, args) { job.encode('jpg', args).apply }
    end
    assert_equal 'jpeg', job.encode('jpg', '-quality 90').apply.format
  end

  test 'strips EXIF, so a photo does not give away where it was taken' do
    pixels = (Vips::Image.black(100, 100) + 100).cast(:uchar).copy
    pixels.set_type(GObject::GSTR_TYPE, 'exif-ifd0-Artist', 'Someone')
    job = app.create(pixels.write_to_buffer('.jpg'), 'name' => 'photo.jpg')
    assert_includes Vips::Image.new_from_buffer(job.data, '').get_fields, 'exif-data'

    [job.thumb('50x50'), job.encode('jpg', '-quality 90')].each do |derivative|
      assert_not_includes vips(derivative).get_fields, 'exif-data'
    end
  end

  test 'keeps every frame of an animated GIF' do
    # Four 40x30 frames, each its own colour, as a GIF writer merges frames that are the same
    frames = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]].map { |colour| Vips::Image.black(40, 30) + colour }
    frames = Vips::Image.arrayjoin(frames, across: 1).cast(:uchar).copy(interpretation: :srgb)
    frames.set_type(GObject::GINT_TYPE, 'page-height', 30)
    assert_equal 4, Vips::Image.new_from_buffer(frames.write_to_buffer('.gif'), '', n: -1).get('n-pages')
    job = app.create(frames.write_to_buffer('.gif'), 'name' => 'animation.gif')

    thumb = Vips::Image.new_from_buffer(job.thumb('20x20').apply.data, '', n: -1)
    assert_equal [4, 20, 15], [thumb.get('n-pages'), thumb.width, thumb.get('page-height')]
  end
end
