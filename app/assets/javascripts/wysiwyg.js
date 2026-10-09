// Rich text: each textarea.wysiwyg becomes a CKEditor (our build, ext/ckeditor.js), its toolbar sticking below the fixed header
$(function () {
  const editors = []

  function offsetToolbars () {
    const headerHeight = fixedHeaderHeight()
    editors.forEach(function (editor) {
      if (editor.ui && editor.ui.view && editor.ui.view.stickyPanel) {
        editor.ui.view.stickyPanel.viewportTopOffset = headerHeight
      }
    })
  }

  $(window).on('resize', offsetToolbars)

  onContentLoaded(function () {
    $('textarea.wysiwyg').once('wysiwyg').each(function () {
      const textarea = this
      ClassicEditor.create(textarea, {
        toolbar: {
          viewportTopOffset: fixedHeaderHeight()
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
        offsetToolbars()

        textarea.dispatchEvent(new CustomEvent('wysiwyg:ready', {
          bubbles: true,
          detail: { editor: editor }
        }))

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
  })
})
