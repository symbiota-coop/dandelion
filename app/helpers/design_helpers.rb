Dandelion::App.helpers do
  # The design guide's sections (/design): id => [nav label, heading]
  def design_sections
    {
      'colour' => %w[Colour Colour],
      'type' => %w[Type Typography],
      'shape' => ['Shape', 'Radius, elevation, spacing'],
      'layout' => ['Layout', 'Page shell'],
      'components' => %w[Components Components],
      'theming' => %w[Theming Theming]
    }
  end

  # A numbered section of the design guide, with an optional intro. Pass HTML in intro as html_safe
  def design_section(id, intro = nil, &)
    concat_content partial(:'design/section', locals: {
                             id: id,
                             number: design_sections.keys.index(id) + 1,
                             title: design_sections[id].last,
                             intro: intro,
                             body: capture_html(&)
                           })
  end

  # A subsection of the design guide: a heading and optional note above its body. col adds grid classes to the wrapper
  def design_subsection(title, note = nil, col: nil, &)
    concat_content partial(:'design/subsection', locals: { title: title, note: note, col: col, body: capture_html(&) })
  end
end
