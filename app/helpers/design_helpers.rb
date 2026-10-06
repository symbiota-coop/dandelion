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
    account = FactoryBot.build(:account, name: name, username: name.parameterize, has_signed_in: !private, location: 'Hackney, London', **attributes)
    image = design_sample_image("/images/samples/#{photo}.jpg")
    account.define_singleton_method(:image) { image }
    account
  end

  # An unsaved event, with its organisation, facilitators and tags built in memory from the factories, so the guide
  # renders the real partials. Nothing is saved: build keeps the records in memory, and has_many_through reads an
  # unsaved record's join documents from memory
  def design_sample_event
    @design_sample_event ||= begin
      organisation = FactoryBot.build(:organisation, name: 'Breathwork Collective', slug: 'breathwork-collective', stripe_pk: nil, stripe_sk: nil)
      start_time = Time.zone.now.next_occurring(:saturday).change(hour: 19)
      event = FactoryBot.build(:event, organisation: organisation, name: 'Breathwork and sound journey', slug: 'breathwork-and-sound-journey',
                                       location: 'Hackney, London', start_time: start_time, end_time: start_time + 3.hours,
                                       featured: true, sold_out_cache: true, image_width_unmagic: 992, image_height_unmagic: 496)
      [['Maya Okoro', 'maya'], ['Sam Lee', 'jonas']].each { |name, photo| event.event_facilitations.build(account: design_sample_account(name, photo)) }
      %w[breathwork sound healing].each { |name| event.event_tagships.build(event_tag: EventTag.new(name: name)) }
      image = design_sample_image
      event.define_singleton_method(:image) { image }
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
