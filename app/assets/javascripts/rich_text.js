// Rich text: links, line breaks, Read more and embeds in text from people and from the editor
$(function () {
  onContentLoaded(function () {
    $('.linkify').once('linkify').linkify({ target: { url: '_blank' } })

    // Shorten long URLs shown as link text to their origin, e.g. https://example.com/...
    $('.compact-urls').once('compact-urls').find('a').each(function () {
      const text = $(this).text()
      const parts = text.split('/')
      if (/^https?:\/\//.test(text) && text.length > 50 && parts.length > 3) $(this).text(parts[0] + '//' + parts[2] + '/...')
    })

    $('.nl2br').once('nl2br').each(function () {
      $(this).html($(this).html().replace(/(?:\r\n|\r|\n)/g, '<br>'))
    })

    $('.read-more').once('read-more').each(function () {
      const $element = $(this)
      const html = $element.html()
      const brIndex = html.indexOf('<br')

      if (brIndex !== -1) {
        const beforeBr = html.substring(0, brIndex)

        // Keep the full content for the Read more link below
        $element.data('full-content', html)
        $element.html(beforeBr + '<br /><a href="javascript:;" class="read-more-toggle">Read more</a>')
      }
    })

    $('.links-blank').once('links-blank').each(function () {
      $('a[href^=http]', this).attr('target', '_blank')
    })

    if (typeof iframely !== 'undefined') {
      $('oembed[url]').once('iframely').each(function () {
        iframely.load(this, $(this).attr('url'))
        if ($(this).parent().is('figure.media')) { $(this).parent().removeClass('media') }
      })
    }
  })

  // Expand a .read-more for good
  $(document).on('click', '.read-more-toggle', function (e) {
    e.preventDefault()
    const $element = $(this).closest('.read-more')
    $element.html($element.data('full-content'))
  })
})
