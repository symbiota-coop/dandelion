// Rich text: each textarea.wysiwyg becomes a CKEditor (our build, ext/ckeditor.js), its toolbar sticking below the fixed header
$(function () {
  const editors = []

  // CKEditor's balloons (the link form, from Cmd-K or the link button) are at the end of the body, outside an open
  // modal, whose focus trap would pull the focus back into it as one opens: to the modal's first button, scrolling it
  // to the top and closing the balloon. So focus moving into one doesn't reach the trap (a listener on document)
  window.addEventListener('focusin', function (e) {
    if (e.target.closest && e.target.closest('.ck-body-wrapper') && document.querySelector('.modal.show')) e.stopImmediatePropagation()
  }, true)

  function offsetToolbars () {
    const headerHeight = fixedHeaderHeight()
    editors.forEach(function (editor) {
      editor.ui.viewportOffset = { top: headerHeight }
    })
  }

  $(window).on('resize', offsetToolbars)

  onContentLoaded(function () {
    $('textarea.wysiwyg').once('wysiwyg').each(function () {
      const textarea = this
      ClassicEditor.create(textarea, {
        ui: {
          viewportOffset: { top: fixedHeaderHeight() }
        },
        simpleUpload: {
          uploadUrl: '/upload'
        },
        mediaEmbed: {
          removeProviders: ['facebook', 'twitter', 'instagram', 'googleMaps', 'flickr']
        }
      }).then(editor => {
        textarea.ckeditorInstance = editor
        editors.push(editor)
        // Keep the textarea up to date as it's typed in: CKEditor writes it only as the form submits, after the
        // browser has checked a required one is filled in (a private session's How to book), so it would stay empty
        // and the form not submit
        editor.model.document.on('change:data', () => editor.updateSourceElement())
        offsetToolbars()

        textarea.dispatchEvent(new CustomEvent('wysiwyg:ready', {
          bubbles: true,
          detail: { editor: editor }
        }))

        editor.editing.view.document.on('clipboardInput', (evt, data) => {
          const content = data.dataTransfer.getData('text/html')

          if (content) {
            const domParser = new DOMParser()
            const documentFragment = domParser.parseFromString(content, 'text/html')

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

            data.content = editor.data.processor.toView(documentFragment.body.innerHTML)
          }
        })
      }).catch(error => {
        console.error(error)
      })
    })
  })
})
