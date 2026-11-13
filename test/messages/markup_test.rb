require_relative '../test_config'

# The markup helpers (app/helpers/markup_helpers.rb) render what people write: markdown (md), messages (message_html),
# our own docs (docs_html) and the bits of markup around them. Each is given hostile input here, checking what comes
# out is safe and that legitimate markup still renders, and the browser tests check a payload doesn't run on the page
class MarkupHelpersTest < ActiveSupport::TestCase
  include Capybara::DSL

  # Each sets window.xss if it runs
  PAYLOADS = [
    '<script>window.xss = 1</script>',
    '<img src="x" onerror="window.xss = 1">',
    '<svg onload="window.xss = 1"><circle r="1"></circle></svg>',
    '<iframe src="javascript:window.xss = 1"></iframe>',
    '<iframe srcdoc="<script>parent.xss = 1</script>"></iframe>',
    '<a href="javascript:window.xss = 1">js</a>',
    '<a href="JaVaScRiPt:window.xss = 1">mixed case</a>',
    '<a href="&#x6A;&#x61;&#x76;&#x61;&#x73;&#x63;&#x72;&#x69;&#x70;&#x74;&#x3A;window.xss = 1">entities</a>',
    '<a href="java&#x09;script:window.xss = 1">tab</a>',
    '<a href=" javascript:window.xss = 1">leading space</a>',
    '<a href="jAvAsCrIpT&colon;window.xss = 1">named colon</a>',
    '<a href="vbscript:msgbox(1)">vbscript</a>',
    '<a href="data:text/html;base64,PHNjcmlwdD53aW5kb3cueHNzID0gMTwvc2NyaXB0Pg==">data</a>',
    '<a href="https://example.com" onclick="window.xss = 1" onmouseover="window.xss = 1">handlers</a>',
    '<details open ontoggle="window.xss = 1">d</details>',
    '<input autofocus onfocus="window.xss = 1">',
    '<video src="x" onerror="window.xss = 1"></video>',
    '<object data="javascript:window.xss = 1"></object><embed src="javascript:window.xss = 1">',
    '<math><mi xlink:href="javascript:window.xss = 1">m</mi></math>',
    '<form action="javascript:window.xss = 1"><button>go</button></form>',
    '<base href="javascript:window.xss = 1/"><meta http-equiv="refresh" content="0;url=javascript:window.xss = 1">',
    '<scr<script>ipt>window.xss = 1</script>',
    '<<script>script>window.xss = 1<</script>/script>',
    '<noscript><p title="</noscript><img src=x onerror=window.xss=1>"></noscript>',
    '<oembed url="javascript:window.xss = 1"></oembed>',
    '<table background="javascript:window.xss = 1"><tr><td>t</td></tr></table>',
    '<img src="data:image/svg+xml;base64,PHN2ZyBvbmxvYWQ9IndpbmRvdy54c3MgPSAxIj48L3N2Zz4=">'
  ].freeze

  MARKDOWN_PAYLOADS = [
    '[md link](javascript:window.xss = 1)',
    '[md link](JaVaScRiPt:window.xss = 1)',
    '[md link](jav&#x61;script:window.xss = 1)',
    '[md link](&#106;avascript:window.xss = 1)',
    '[md link](vbscript:msgbox(1))',
    '[md link](data:text/html;base64,PHNjcmlwdD4=)',
    '![md image](javascript:window.xss = 1)',
    '![x" onerror="window.xss = 1](https://example.com/a.png)',
    '[title](https://example.com "t\" onmouseover=\"window.xss = 1")',
    "```\n<script>window.xss = 1</script>\n```",
    'https://example.com/"onmouseover="window.xss=1',
    'https://example.com/<img src=x onerror=window.xss=1>'
  ].freeze

  def helpers
    Dandelion::App.new!
  end

  def fragment(html)
    Nokogiri::HTML5.fragment(html.to_s)
  end

  def hrefs(doc)
    doc.css('a').map { |a| a['href'] }
  end

  # No script, no handler, no URL that runs script, nothing that frames or submits
  def assert_safe(html)
    doc = fragment(html)
    assert_empty doc.css('script, iframe, object, embed, svg, math, form, input, button, base, meta, link, video, details, noscript'), html
    doc.css('*').each do |el|
      el.attributes.each do |name, attr|
        refute name.start_with?('on'), "#{name} in #{html}"
        next unless %w[href src action formaction background xlink:href url data srcdoc].include?(name)

        refute_match(/\A\s*(javascript|vbscript|data):/i, attr.value.gsub(/[\u0000- ]/, ''), "#{name} in #{html}")
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # md
  # ═══════════════════════════════════════════════════════════════════════════

  test 'md removes scripts, handlers, frames and script URLs written as HTML' do
    PAYLOADS.each { |payload| assert_safe(helpers.md("Before #{payload} after")) }
  end

  test 'md removes script URLs and handlers written as markdown' do
    MARKDOWN_PAYLOADS.each { |payload| assert_safe(helpers.md(payload)) }

    doc = fragment(helpers.md('[md link](JaVaScRiPt:window.xss = 1)'))
    assert_equal 'md link', doc.at_css('a').text
    assert_nil doc.at_css('a')['href']
    assert_equal "<script>window.xss = 1</script>\n", fragment(helpers.md("```\n<script>window.xss = 1</script>\n```")).at_css('pre code').text
  end

  test 'md keeps an image alt containing quotes as text' do
    img = fragment(helpers.md('![x" onerror="window.xss = 1](https://example.com/a.png)')).at_css('img')

    assert_equal 'https://example.com/a.png', img['src']
    assert_equal 'x" onerror="window.xss = 1', img['alt']
    assert_nil img['onerror']
  end

  test 'md autolinks a URL with quotes in it without breaking out of the href' do
    a = fragment(helpers.md('https://example.com/"onmouseover="window.xss=1')).at_css('a')

    assert_equal ['href'], a.attributes.keys
    assert_equal 'https://example.com/%22onmouseover=%22window.xss=1', a['href']
  end

  test 'md keeps only allowed classes and CSS properties' do
    html = helpers.md(<<~HTML)
      <div class="position-fixed top-0 z-3 offcanvas show lead">panel</div>
      <p style="position: fixed; top: 0; inset: 0; z-index: 9999; color: red">styled</p>
      <span style="background-color: url(javascript:window.xss = 1)">url</span>
      <h2 style="color: red; width: expression(alert(1))">expression</h2>
      <figure class="image image-style-side" style="width: 50%"><img src="https://example.com/a.png"></figure>
    HTML
    doc = fragment(html)

    assert_equal 'lead', doc.at_css('div')['class']
    assert_equal 'color: red', doc.at_css('p')['style'].strip.delete_suffix(';')
    assert_nil doc.at_css('span')['style']
    refute_includes doc.at_css('h2')['style'], 'expression'
    assert_equal 'image image-style-side', doc.at_css('figure')['class']
    assert_equal 'width: 50%', doc.at_css('figure')['style']
  end

  test 'md keeps only http(s) oembed URLs' do
    assert_nil fragment(helpers.md('<oembed url="javascript:window.xss = 1"></oembed>')).at_css('oembed')['url']
    assert_equal 'https://www.youtube.com/watch?v=1',
                 fragment(helpers.md('<oembed url="https://www.youtube.com/watch?v=1"></oembed>')).at_css('oembed')['url']
  end

  test 'md closes unclosed tags so they cannot swallow the page' do
    html = helpers.md('<b><i>unclosed <a href="https://example.com">link')

    assert_equal fragment(html).to_html, html.to_s
    assert_equal 'unclosed link', fragment("#{html}<p>after</p>").css('b').first.text.strip
  end

  test 'md renders legitimate markdown' do
    html = helpers.md(<<~MD)
      ## Heading

      **bold** _em_ [link](https://example.com/a?b=1&c=2) <https://auto.example.com> www.example.org someone@example.com [mail](mailto:someone@example.com) [relative](/e/slug)

      | a | b |
      |---|---|
      | 1 | 2 |

      ```ruby
      puts 1 < 2
      ```
    MD
    doc = fragment(html)

    assert_equal 'Heading', doc.at_css('h2').text
    assert_equal 'bold', doc.at_css('strong').text
    assert_equal 'em', doc.at_css('em').text
    assert_equal ['https://example.com/a?b=1&c=2', 'https://auto.example.com', 'http://www.example.org', 'mailto:someone@example.com',
                  'mailto:someone@example.com', '/e/slug'], hrefs(doc)
    assert_equal %w[1 2], doc.css('td').map(&:text)
    assert_equal "puts 1 < 2\n", doc.at_css('code').text
    assert html.html_safe?
  end

  test 'md hard_wrap turns single newlines into line breaks' do
    assert_equal 1, fragment(helpers.md("one\ntwo", hard_wrap: true)).css('br').length
    assert_empty fragment(helpers.md("one\ntwo")).css('br')
  end

  test 'md inline keeps HTML as text, links only to http(s) and mailto, and drops the paragraph' do
    (PAYLOADS + MARKDOWN_PAYLOADS).each { |payload| assert_safe(helpers.md(payload, inline: true)) }

    assert_equal '&lt;script&gt;window.xss = 1&lt;/script&gt; <strong>bold</strong>', helpers.md('<script>window.xss = 1</script> **bold**', inline: true)
    assert_equal '[x](javascript:window.xss = 1)', helpers.md('[x](javascript:window.xss = 1)', inline: true)
    assert_equal '<a href="https://example.com">x</a> <a href="mailto:a@example.com">m</a>',
                 helpers.md('[x](https://example.com) [m](mailto:a@example.com)', inline: true)
  end

  test 'md trusted renders our own HTML as written' do
    html = helpers.md('<div class="position-fixed" data-x="1">ours</div>', trusted: true)

    assert_equal 'position-fixed', fragment(html).at_css('div')['class']
    assert_equal '1', fragment(html).at_css('div')['data-x']
  end

  test 'md renders nil as empty and long input quickly' do
    assert_equal '', helpers.md(nil)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    html = helpers.md("#{'word ' * 100_000}\n\n#{'[' * 20_000}\n\nhttps://example.com/#{'a' * 50_000}")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert_equal "https://example.com/#{'a' * 50_000}", fragment(html).at_css('a')['href']
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # message_html
  # ═══════════════════════════════════════════════════════════════════════════

  def message_html(body)
    helpers.message_html(Message.new(body: body))
  end

  test 'message_html removes scripts, handlers, frames and script URLs' do
    PAYLOADS.each { |payload| assert_safe(message_html("Before #{payload} after")) }
    MARKDOWN_PAYLOADS.each { |payload| assert_safe(message_html(payload)) }
  end

  test 'message_html does not autolink script URLs' do
    html = message_html('javascript:window.xss=1 vbscript:msgbox(1) data:text/html,x https://example.com')

    assert_equal ['https://example.com'], hrefs(fragment(html))
  end

  test 'message_html line breaks inside an attribute do not make a script URL' do
    links = fragment(message_html(%(<a href="javascript\nscript:window.xss = 1">x</a>))).css('a')

    assert(links.none? { |a| a['href'].to_s.match?(/\Ajavascript:/i) })
  end

  test 'message_html autolinks URLs, keeps line breaks, and shows what was typed, markup and < included' do
    html = message_html("Hi <b>there</b>, 3 < 5 and see <name> here\nsee https://example.com/a?b=1&c=2 and www.example.org\nor mail someone@example.com")
    doc = fragment(html)

    assert_equal 2, doc.css('br').length
    assert_nil doc.at_css('b')
    assert_includes doc.text, 'Hi <b>there</b>, 3 < 5 and see <name> here'
    assert_equal ['https://example.com/a?b=1&c=2', 'http://www.example.org', 'mailto:someone@example.com'], hrefs(doc)
  end

  test 'message_html shows deeply nested markup as text rather than failing' do
    html = message_html("#{'<b>' * 500}deep#{'</b>' * 500}")

    assert_includes fragment(html).text, "#{'<b>' * 500}deep"
  end

  test 'message_html renders a long message quickly' do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    html = message_html("#{"line https://example.com\n" * 5_000}#{'x' * 100_000}")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert_equal 5_000, fragment(html).css('a').length
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # docs_html, timeago, u, blurred_image_tag
  # ═══════════════════════════════════════════════════════════════════════════

  test 'docs_html gives headings ids from their text, contents and searchable sections' do
    html = helpers.md(<<~MD, trusted: true)
      Intro

      ## Prices & "quotes"

      Text one

      ### Sub heading

      Text two

      | a |
      |---|
      | 1 |

      <div class="raw-html-embed">video</div>

      > Transcript
    MD
    page = helpers.docs_html(html, slug: 'guide', name: 'Guide')
    doc = fragment(page[:html])

    assert_equal 'prices-quotes', doc.at_css('h2')['id']
    assert_equal [{ id: 'prices-quotes', text: 'Prices & "quotes"',
                    h3s: [{ id: 'sub-heading', text: 'Sub heading' }] }], page[:headings]
    assert_equal 'doc-table-wrap', doc.at_css('table').parent['class']
    assert_equal 'table table-bordered', doc.at_css('table')['class']
    assert_equal 'Show transcript', doc.at_css('details.doc-transcript summary').text
    assert_equal %w[guide prices-quotes sub-heading], page[:sections].pluck(:headingId)
    assert_equal 'Intro', page[:sections].first[:text]
  end

  test 'docs_html keeps a heading written as HTML text, not markup' do
    page = helpers.docs_html('<h2>&lt;img src=x onerror=alert(1)&gt;</h2>', slug: 's', name: 'S')

    assert_empty fragment(page[:html]).css('img')
    assert_equal '<img src=x onerror=alert(1)>', page[:headings].first[:text]
  end

  test 'timeago renders a relative time for a time' do
    time = Time.utc(2026, 1, 2, 3, 4, 5)
    el = fragment(helpers.timeago(time)).at_css('relative-time')

    assert_equal '2026-01-02T03:04:05Z', el['datetime']
    assert_equal time.to_s, el.text
  end

  test 'u escapes quotes and spaces in a URL so it cannot break out of an attribute' do
    assert_equal 'https://example.com/a%22%20onload=%22alert(1)%3E', helpers.u('https://example.com/a" onload="alert(1)>')
    assert_nil helpers.u(nil)
  end

  test 'blurred_image_tag escapes its image URLs' do
    image = Struct.new(:url) do
      def thumb(_size) = self
    end.new('https://example.com/a" onerror="window.xss = 1')
    img = fragment(helpers.blurred_image_tag(image, width: 4, height: 3, md_size: '992x992')).at_css('img')

    assert_equal 'https://example.com/a%22%20onerror=%22window.xss%20=%201', img['src']
    assert_equal img['src'], img['data-src']
    assert_equal img['src'], img['data-src-md']
    assert_nil img['onerror']
    assert_equal 'aspect-ratio: 4 / 3', img['style']
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # In the browser
  # ═══════════════════════════════════════════════════════════════════════════

  def assert_xss_did_not_run
    assert_equal 'undefined', page.evaluate_script('typeof window.xss')
  end

  test 'a hostile message does not run in the thread' do
    account = FactoryBot.create(:account)
    other = FactoryBot.create(:account)
    [account, other].each { |a| a.set(email_confirmed: true, can_message: true) }
    Message.create!(messenger: other, messengee: account,
                    body: "Hostile message\n#{(PAYLOADS + MARKDOWN_PAYLOADS).join("\n")}")

    sign_in(account)
    visit "/messages/#{other.username}"
    thread = find('.message-thread')
    assert thread.has_content?('Hostile message')
    assert_xss_did_not_run

    # A message is plain text, so the payloads show as typed, with no links or elements of their own to run
    assert thread.has_content?('<script>')
    message = thread.find('.widget-chat-message', text: 'Hostile message')
    message.all('a').each { |link| refute_match(/\A\s*(javascript|vbscript|data):/i, link[:href].to_s) }
    assert message.has_no_css?('script, iframe, img, svg, style, [onmouseover]')
  end

  test 'a hostile ticket type description does not run on the event page' do
    create_event(prices: [10, 20])
    @event.ticket_types.first.update_attributes!(description: "Hostile description\n\n#{(PAYLOADS + MARKDOWN_PAYLOADS).join("\n\n")}")

    visit "/e/#{@event.slug}"
    assert page.has_content?('Hostile description')
    assert_xss_did_not_run
    find('.ticket-type-description a', text: 'handlers').hover
    assert_xss_did_not_run
  end

  test 'md drops style elements, and message_html shows them as text, so neither restyles the whole page' do
    css = '<style>body { background-color: black; color: black } .message-thread { width: 0 }</style>'

    md = helpers.md("#{css}\n\nText")
    assert_empty fragment(md).css('style')
    refute_includes md, 'background-color'
    assert_includes md, 'Text'

    message = fragment(message_html("#{css}Text"))
    assert_empty message.css('style')
    assert_includes message.text, "#{css}Text"
  end

  test 'a message with a style element does not restyle the thread' do
    account = FactoryBot.create(:account)
    other = FactoryBot.create(:account)
    [account, other].each { |a| a.set(email_confirmed: true, can_message: true) }
    Message.create!(messenger: other, messengee: account, body: 'Restyling<style>body { background-color: rgb(1, 2, 3) }</style>')

    sign_in(account)
    visit "/messages/#{other.username}"
    assert find('.message-thread').has_content?('Restyling')
    refute_equal 'rgb(1, 2, 3)', page.evaluate_script('getComputedStyle(document.body).backgroundColor')
  end
end
