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
    @design_section = id
    (@design_toc ||= {})[id] = []
    concat_content partial(:'design/section', locals: {
                             id: id,
                             number: design_sections.keys.index(id) + 1,
                             title: design_sections[id].last,
                             intro: intro,
                             body: capture_html(&)
                           })
  end

  # A stand-in for a Dragonfly image, serving the sample photo at any size: a real one would store a thumbnail
  # (and a DragonflyJob) the first time each size's url is asked for
  def design_sample_image(path = '/images/test-event.jpg')
    (@design_sample_images ||= {})[path] ||= Struct.new(:url) { def thumb(_size) = self }.new(path)
  end

  # An unsaved account, built from the factory, with one of the sample photos (maya, jonas or amara) as its image.
  # Signed in, so it's publicly visible, unless private: true
  def design_sample_account(name, photo, private: false, **attributes)
    account = FactoryBot.build(:account, name: name, username: name.parameterize(separator: '_'), has_signed_in: !private, location: 'Hackney, London', **attributes)
    image = design_sample_image("/images/samples/#{photo}.jpg")
    account.define_singleton_method(:image) { image }
    account
  end

  # The sample events' organisation, unsaved
  def design_sample_organisation
    @design_sample_organisation ||= FactoryBot.build(:organisation, name: 'Breathwork Collective', slug: 'breathwork-collective')
  end

  # An unsaved event of the sample organisation's, built from the factory, with the sample photo as a stand-in image.
  # It starts at 7pm on the given day and runs for three hours, or for the given days; evergreen events have no dates
  def design_build_event(name, day: Date.today.next_occurring(:saturday), days: nil, **attributes)
    start_time = day.in_time_zone.change(hour: 19)
    end_time = days ? start_time + days.days : start_time + 3.hours
    times = attributes[:evergreen] ? { start_time: nil, end_time: nil } : { start_time: start_time, end_time: end_time }
    event = FactoryBot.build(:event, organisation: design_sample_organisation, name: name, slug: name.parameterize, location: 'Hackney, London',
                                     image_width_unmagic: 992, image_height_unmagic: 496, **times, **attributes)
    image = design_sample_image
    event.define_singleton_method(:image) { image }
    event
  end

  # The guide's main sample event, with facilitators and tags built in memory, so the guide renders the real partials.
  # Nothing is saved: build keeps the records in memory, and has_many_through reads an unsaved record's join documents from memory
  def design_sample_event
    @design_sample_event ||= begin
      event = design_build_event('Breathwork and sound journey', featured: true, sold_out_cache: true)
      [['Maya Okoro', 'maya'], ['Sam Lee', 'jonas']].each { |name, photo| event.event_facilitations.build(account: design_sample_account(name, photo)) }
      %w[breathwork sound healing].each { |name| event.event_tagships.build(event_tag: EventTag.new(name: name)) }
      event
    end
  end

  # A subsection of the design guide: a heading and optional note above its body. col adds grid classes to the wrapper.
  # Its id is the section's plus its title, and it's listed under its section in the nav (@design_toc)
  def design_subsection(title, note = nil, col: nil, &)
    id = "#{@design_section}-#{title.parameterize}"
    @design_toc[@design_section] << [id, title]
    concat_content partial(:'design/subsection', locals: { id: id, title: title, note: note, col: col, body: capture_html(&) })
  end
end
