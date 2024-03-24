function nl2br (str) {
  return str.replace(/(?:\r\n|\r|\n)/g, '<br>')
}

$.fn.serializeObject = function () {
  const o = {}
  const a = this.serializeArray()
  $.each(a, function () {
    if (o[this.name]) {
      if (!o[this.name].push) {
        o[this.name] = [o[this.name]]
      }
      o[this.name].push(this.value || '')
    } else {
      o[this.name] = this.value || ''
    }
  })
  return o
}

$(function () {
  function ajaxCompleted () {
    $('input[type=file]').change(function () {
      if (this.files.length > 0 && this.files[0].size > 10e6) {
        alert('That file is too large, the maximum file size is 10MB. Please resize it before uploading.')
        $(this).val('')
      }
    })

    $('[data-confirm], [href$="destroy"]').not('[data-confirm-registered]').attr('data-confirm-registered', 'true').each(function () {
      $(this).click(function () {
        $(this).removeClass('no-trigger')

        const message = $(this).data('confirm') || 'Are you sure?'
        if (!confirm(message)) {
          $(this).addClass('no-trigger')
          return false
        }
      })
    })

    $('form.add-placeholders label[for]').not('[data-placeholders-added]').attr('data-placeholders-added', true).each(function () {
      const input = $(this).next().children().first()
      if (!$(input).attr('placeholder')) { $(input).attr('placeholder', $.trim($(this).text())) }
    })

    // use classes here, because flatpickr copies classes (resulting in multiple calls) but not data attributes
    $('.datepicker').not('.flatpickr-registered').addClass('flatpickr-registered').flatpickr({
      altInput: true,
      altFormat: 'Y-m-d'
    })
    $('.datetimepicker').not('.flatpickr-registered').addClass('flatpickr-registered').flatpickr({
      altInput: true,
      altFormat: 'J F Y, H:i',
      enableTime: true,
      time_24hr: true
    })

    $('[id=comment_body]').not('[data-tributed]').attr('data-tributed', true).each(function () {
      const tribute = new Tribute({
        values: function (text, callback) {
          $.get('/network?q=' + text, function (data) {
            callback(data)
          })
        },
        selectTemplate: function (item) {
          return '[@' + item.original.key + '](@' + item.original.value + ')'
        }
      })
      tribute.attach(this)
    })

    $('.tagify').not('[data-tagified]').attr('data-tagified', true).each(function () {
      $(this).html($(this).html().replace(/\[@([\w\s'-.]+)\]\(@(\w+)\)/g, '<a href="/u/$2">$1</a>'))
    })

    $('[id=comment_subject], [id=comment_body]').not('[data-show-comment-options-on-focus]').attr('data-show-comment-options-on-focus', true).focus(function () {
      $(this.form).find('.comment-options').removeClass('d-none')
    })

    $('[data-toggle="tooltip"]').not('[data-tooltipd]').attr('data-tooltipd', true).tooltip({
      html: true,
      title: function () {
        if ($(this).attr('title').length > 0) { return $(this).attr('title') } else { return $(this).next('span').html() }
      }
    })

    $('.block').not('[data-block-hover], .infowindow .block').attr('data-block-hover', true).hover(
      function () {
        $('.block-edit', this).show()
      },
      function () {
        $('.block-edit', this).hide()
      }
    )

    $('abbr.timeago').not('[data-timeago-done]').attr('data-timeago-done', true).timeago()

    $('[data-account-username]').not('#modal [data-account-username]').not('[data-modalized]').attr('data-modalized', true).click(function () {
      $('#modal .modal-content').load('/u/' + $(this).attr('data-account-username'), function () {
        $('#modal').modal('show')
        $('[data-toggle="tooltip"]').tooltip('hide')
      })
    })

    $('.linkify').not('[data-linkified]').attr('data-linkified', true).linkify()

    $('.compact-urls').not('[data-compact-urls]').attr('data-compact-urls', true).each(function () {
      $(this).html($(this).html().replace(/<a (.*)>(.*)<\/a>/, function (match, p1, p2) {
        const parts = p2.split('/')
        let t
        if (p2.match(/^(http|https):\/\//) && p2.length > 50 && parts.length > 3) {
          t = parts[0] + '//' + parts[2] + '/...'
        } else {
          t = p2
        }
        return '<a ' + p1 + '>' + t + '</a>'
      }))
    })

    $('.nl2br').not('[data-nl2br]').attr('data-nl2br', true).each(function () {
      $(this).html(nl2br($(this).html()))
    })

    $('textarea[id=comment_body], textarea.autosize').not('[data-autosized]').attr('data-autosized', true).each(function () {
      autosize(this)
    })

    $('oembed[url]').not('[data-embedded]').attr('data-embedded', true).each(function () {
      iframely.load(this, $(this).attr('url'))
      if ($(this).parent().is('figure.media')) { $(this).parent().removeClass('media') }
    })

    $('.links-blank').not('[data-links-blank-done]').attr('data-links-blank-done', true).each(function () {
      $('a[href^=http]', this).attr('target', '_blank')
    })
  }

  $(document).ajaxComplete(function () {
    ajaxCompleted()
  })
  ajaxCompleted()

  hljs.highlightAll()

  $('input[type=hidden].lookup').each(function () {
    $(this).lookup({
      lookup_url: $(this).attr('data-lookup-url'),
      placeholder: $(this).attr('placeholder'),
      id_param: 'id'
    })
  })

  $('[data-upload-url]').click(function () {
    const form = $('<form action="' + $(this).attr('data-upload-url') + '" method="post" enctype="multipart/form-data"><input style="display: none" type="file" name="upload"></form>')
    form.insertAfter(this)
    form.find('input').click().change(function () {
      this.form.submit()
    })
  })

  $('input[type=text].slug').each(function () {
    const slug = $(this)
    const start_length = slug.val().length
    const pos = $.inArray(this, $('input', this.form)) - 1
    const title = $($('input', this.form).get(pos))
    slug.focus(function () {
      slug.data('focus', true)
    })
    title.keyup(function () {
      if (start_length == 0 && slug.data('focus') != true) { slug.val(title.val().toLowerCase().replace(/ /g, '-').replace(/[^a-z0-9-]/g, '')) }
    })
  })

  $('input[type=text].shorturl').each(function () {
    const input = $(this)
    const stem = $(this).prev()
    const link = $(this).next()
    link.attr('data-toggle', 'tooltip')
    link.attr('title', 'Click to copy')
    link.click(function () {
      navigator.clipboard.writeText(stem.text() + input.val())
      link.attr('title', 'Copied!')
      link.tooltip('dispose').tooltip().tooltip('show')
      return false
    })
    input.keydown(function () {
      link.hide()
    })
  })

  $(document).on('click', 'a.popup', function () {
    window.open(this.href, null, 'scrollbars=yes,width=600,height=600,left=150,top=150').focus()
    return false
  })

  if (window.location.hash.startsWith('#photo-')) { $("[data-target='" + window.location.hash + "']").click() }

  $('textarea.wysiwyg').each(function () {
    const textarea = this
    ClassicEditor.create(textarea, {
      simpleUpload: {
        uploadUrl: '/upload'
      },
      mediaEmbed: {
        removeProviders: ['facebook', 'twitter', 'instagram', 'googleMaps', 'flickr']
      }
    }).then(editor => {
      editor.editing.view.document.on('clipboardInput', (evt, data) => {
        const content = data.dataTransfer.getData('text/html')

        if (content) {
          // We have HTML content from the clipboard.
          const domParser = new DOMParser()
          const documentFragment = domParser.parseFromString(content, 'text/html')

          // Traverse the tree and remove color styles.
          const walker = document.createTreeWalker(
            documentFragment,
            NodeFilter.SHOW_ELEMENT,
            {
              acceptNode: function (node) {
                return (node.style.color || node.style.backgroundColor) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP
              }
            }
          )

          while (walker.nextNode()) {
            walker.currentNode.style.removeProperty('color')
            walker.currentNode.style.removeProperty('background-color')
          }

          // Update the clipboard content.
          data.content = editor.data.processor.toView(documentFragment.body.innerHTML)
        }
      })
    }).catch(error => {
      console.error(error)
    })
  })

  $('form.submitOnChange').each(function () {
    $('select, .flatpickr-input, input[type=checkbox]', this).change(function () {
      $(this.form).submit()
    })
  })

  $('.labelize').each(function () {
    $('div.checkbox', this).each(function () {
      const div = this
      $(div).hide()
      const button = $('<a href="javascript:;" class="d-inline-block mb-1 mr-1"><span class="label label-outline-primary">' + $(this).find('label').text() + '</span></a>').insertAfter(this)
      if ($('input[type=checkbox]:checked', div).length > 0) { $('span', button).removeClass('label-outline-primary').addClass('label-primary') }
      $(button).click(function () {
        if ($('input[type=checkbox]:checked', div).length > 0) {
          console.log('unchecking')
          $('input[type=checkbox]', div).prop('checked', false)
          $('span', button).removeClass('label-primary').addClass('label-outline-primary')
        } else {
          console.log('checking')
          $('input[type=checkbox]', div).prop('checked', true)
          $('span', button).removeClass('label-outline-primary').addClass('label-primary')
        }
      })
    })
  })

  $(window).on('beforeunload', function () {
    if ($('#page-container').hasClass('page-sidebar-toggled') && $(window).width() < 768) {
      $('.pace-activity').css('border-top-color', 'white').css('border-left-color', 'white')
    }
    $('.pace-progress').hide()
    $('.pace-inactive').show()
  })

  Pace.stop()
})
