function initQuestionsPreview (inputSelector, previewUrl) {
  const fieldName = inputSelector.replace(/^#\w+?_/, '').replace(/_/g, '-')
  const previewSelector = '#' + fieldName + '-preview'
  const spinnerSelector = '#' + fieldName + '-spinner'
  let timer
  function load () {
    if (!previewUrl) return
    $(previewSelector).load(previewUrl + '?questions=' + encodeURIComponent($(inputSelector).val()), function () {
      $(spinnerSelector).hide()
    })
  }
  $(inputSelector).on('input', function () {
    $(spinnerSelector).show()
    clearTimeout(timer)
    timer = setTimeout(load, 500)
  })
  load()
}

$(function () {

  $.fn.select2.defaults.set('theme', 'bootstrap4')

  function ajaxCompleted () {

    function styleSelectElement (select) {
      if ($(select).find('option:selected').is(':disabled')) {
        $(select).css('color', '#6c757d');
      } else {
        $(select).css('color', '');
      }
    }

    $('select').not('[data-select-styled]').attr('data-select-styled', true).each(function () {
      styleSelectElement(this);
      $(this).removeClass('select-placeholder');
      $(this).change(function () {
        styleSelectElement(this);
      })
    })

    $('.either-or input[type="checkbox"]').not('[data-either-or-registered]').attr('data-either-or-registered', true).change(function () {
      if (this.checked) {
        $('.either-or input[type="checkbox"]').not(this).prop('checked', false);
      }
    });

    $('input[type=file]').not('[data-file-size-check]').attr('data-file-size-check', true).change(function () {
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
      $(this).html($(this).html().replace(/(?:\r\n|\r|\n)/g, '<br>'))
    })

    $('.read-more').not('[data-read-more-processed]').attr('data-read-more-processed', true).each(function () {
      const $element = $(this)
      const html = $element.html()
      const brIndex = html.indexOf('<br')

      if (brIndex !== -1) {
        const beforeBr = html.substring(0, brIndex)

        // Store the full content
        $element.data('full-content', html)

        // Set initial truncated content with ellipsis
        $element.html(beforeBr + '<br /><a href="javascript:;" class="read-more-toggle">Read more</a>')

        // Add click handler - expand permanently
        $element.on('click', '.read-more-toggle', function (e) {
          e.preventDefault()
          // Expand to show full content
          $element.html($element.data('full-content'))
        })
      }
    })

    $('textarea[id=comment_body], textarea.autosize').not('[data-autosized]').attr('data-autosized', true).each(function () {
      autosize(this)
    })

    if (typeof iframely !== 'undefined') {
      $('oembed[url]').not('[data-embedded]').attr('data-embedded', true).each(function () {
        iframely.load(this, $(this).attr('url'))
        if ($(this).parent().is('figure.media')) { $(this).parent().removeClass('media') }
      })
    }

    $('.links-blank').not('[data-links-blank-done]').attr('data-links-blank-done', true).each(function () {
      $('a[href^=http]', this).attr('target', '_blank')
    })

    $('select.lookup').not('[data-lookup-initialized]').attr('data-lookup-initialized', true).each(function () {
      $(this).lookup({
        lookup_url: $(this).attr('data-lookup-url'),
        placeholder: $(this).attr('placeholder'),
        id_param: 'id'
      })
    })

    $('input[type=text].slug, div.slugify input[type=text].shorturl').not('[data-slug-initialized]').attr('data-slug-initialized', true).each(function () {
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

    $('input[type=text].shorturl').not('[data-shorturl-initialized]').attr('data-shorturl-initialized', true).each(function () {
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

    if (window.location.hash.startsWith('#photo-')) { $("[data-target='" + window.location.hash + "']").not('[data-photo-clicked]').attr('data-photo-clicked', true).click() }

    $('textarea.wysiwyg').not('[data-wysiwyg-initialized]').attr('data-wysiwyg-initialized', true).each(function () {
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

    $('input.typeWatch').not('[data-typewatch-initialized]').attr('data-typewatch-initialized', true).typeWatch({ wait: 500, callback: function () { $(this.form).submit() } })

    $('form.submitOnChange').not('[data-submit-on-change-initialized]').attr('data-submit-on-change-initialized', true).each(function () {
      $('select, .flatpickr-input, input[type=checkbox], input[type=month]', this).change(function () {
        $(this.form).submit()
      })
    })

    $('.labelize').not('[data-labelize-initialized]').attr('data-labelize-initialized', true).each(function () {
      $('div.checkbox', this).each(function () {
        const div = this
        $(div).hide()
        const button = $('<a href="javascript:;" class="d-inline-block mb-1 mr-1"><span class="label label-outline-primary">' + $(this).find('label').text() + '</span></a>').insertAfter(this)
        if ($('input[type=checkbox]:checked', div).length > 0) { $('span', button).removeClass('label-outline-primary').addClass('label-primary') }
        $(button).click(function () {
          if ($('input[type=checkbox]:checked', div).length > 0) {
            $('input[type=checkbox]', div).prop('checked', false)
            $('span', button).removeClass('label-primary').addClass('label-outline-primary')
          } else {
            $('input[type=checkbox]', div).prop('checked', true)
            $('span', button).removeClass('label-outline-primary').addClass('label-primary')
          }
        })
      })
    })

    $('.colorpicker').not('[data-coloris]').attr('data-coloris', true)
    Coloris({ alpha: false });

    $('.search.well .checkbox-inline input[type="checkbox"]').not('[data-search-checkbox-registered]').attr('data-search-checkbox-registered', true).on('change', function () {
      $(this).closest('.checkbox-inline').toggleClass('checked', this.checked);
    });
  }

  $(document).ajaxComplete(function () {
    ajaxCompleted()
  })
  ajaxCompleted()

  $(window).on('beforeunload', function () {
    if ($('#page-container').hasClass('page-sidebar-toggled') && $(window).width() < 768) {
      $('#page-container').removeClass('page-sidebar-toggled');
      $('[data-click="sidebar-toggled"]').removeClass('active');
    }
    $('.pace-inactive').show() // start spinner as user starts navigating away from page
  })

  $(window).on('pagehide', function () {
    $('.pace-progress').hide()
    $('.pace-inactive').hide() // hide spinner as user leaves page so it doesn't show when pressing back button    
  })

  if (typeof Pace !== 'undefined') {
    Pace.stop()
  }
})
