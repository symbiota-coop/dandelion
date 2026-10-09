// Comments: @ mentions while writing, [@name](@id) mentions shown as profile links, and the comment options on focus.
// Load it before rich_text.js, so mentions become links before .linkify and .nl2br run
$(function () {
  onContentLoaded(function () {
    $('[id=comment_body]').once('tribute').each(function () {
      const tribute = new Tribute({
        values: function (text, callback) {
          $.get('/network?q=' + encodeURIComponent(text), function (data) {
            callback(data)
          })
        },
        selectTemplate: function (item) {
          return '[@' + item.original.key + '](@' + item.original.value + ')'
        }
      })
      tribute.attach(this)
    })

    $('.tagify').once('tagify').each(function () {
      $(this).html($(this).html().replace(/\[@([\w\s'.-]+)\]\(@(\w+)\)/g, '<a href="/u/$2">$1</a>'))
    })
  })

  $(document).on('focusin', '[id=comment_subject], [id=comment_body]', function () {
    $(this.form).find('.comment-options').show()
  })
})
