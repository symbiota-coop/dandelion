Dandelion::App.helpers do
  def library_image_url(path)
    return unless path

    "https://cdn.jsdelivr.net/gh/stephenreid321/stephenreid@master/site#{path}"
  end
end
