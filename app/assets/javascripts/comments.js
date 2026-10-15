// Comments: @username mentions while writing (comments render them as profile links on the server), and the comment options on focus.
$(function () {
  const escapeText = function (text) { return $('<span>').text(text).html() }

  // The @ mention menu: typing @ and part of a name or username in a comment box lists matching people from your
  // network under the box, and picking one (arrows and Enter or Tab, or a click) puts in their @username
  const mentions = {
    $menu: null,
    field: null, // the comment box the menu is open for
    people: [],
    selected: 0,
    request: 0, // the latest request, so slower earlier responses are ignored
    timer: null,

    menu: function () {
      if (!this.$menu) {
        this.$menu = $('<ul class="mention-menu" role="listbox" style="display: none"></ul>').appendTo('body')
        this.$menu.on('mousedown', 'li[data-index]', function (e) {
          e.preventDefault() // keep the comment box focused
          mentions.pick($(this).data('index'))
        })
        this.$menu.on('mousemove', 'li[data-index]', function () {
          mentions.highlight($(this).data('index'))
        })
      }
      return this.$menu
    },

    // The @ and what follows it, if the caret is straight after an @ that starts a word
    query: function (field) {
      const before = field.value.slice(0, field.selectionStart)
      const match = before.match(/(^|\s)@([\w.]*)$/)
      if (!match) return null
      return { text: match[2], start: before.length - match[2].length - 1 }
    },

    update: function (field) {
      const query = this.query(field)
      if (!query) return this.hide()

      this.field = field
      clearTimeout(this.timer)
      if (query.text.length < 2) {
        this.request++
        return this.show([], 'Keep typing a name or username')
      }

      const request = ++this.request
      this.timer = setTimeout(function () {
        $.get('/network?q=' + encodeURIComponent(query.text), function (people) {
          if (request === mentions.request) mentions.show(people.slice(0, 8), 'No one found')
        })
      }, 150)
    },

    show: function (people, emptyText) {
      const $menu = this.menu()
      this.people = people
      this.selected = 0
      $menu.html(people.length
        ? people.map(function (person, index) {
          return '<li role="option" data-index="' + index + '">' +
            '<img class="avatar avatar-xs ' + escapeText(person.avatar_class || '') + '" src="' + escapeText(person.image) + '" alt="">' +
            '<span class="mention-name">' + escapeText(person.key) + '</span>' +
            '<span class="mention-username">@' + escapeText(person.value) + '</span>' +
            '</li>'
        }).join('')
        : '<li class="mention-empty">' + escapeText(emptyText) + '</li>')
      this.highlight(0)

      const $field = $(this.field)
      const offset = $field.offset()
      $menu.css({ top: offset.top + $field.outerHeight(), left: offset.left }).show()
    },

    hide: function () {
      clearTimeout(this.timer)
      this.request++
      this.field = null
      this.people = []
      if (this.$menu) this.$menu.hide()
    },

    highlight: function (index) {
      this.selected = index
      this.menu().children().removeClass('active').filter('[data-index=' + index + ']').addClass('active')
    },

    pick: function (index) {
      const person = this.people[index]
      const field = this.field
      if (!person || !field) return

      // Where the @ is now, in case the caret has moved since the menu opened
      const query = this.query(field)
      if (!query) return this.hide()

      const caret = field.selectionStart
      const mention = '@' + person.value + ' '
      field.value = field.value.slice(0, query.start) + mention + field.value.slice(caret)
      field.selectionStart = field.selectionEnd = query.start + mention.length
      this.hide()
      $(field).trigger('input')
    }
  }

  $(document).on('input click', '[id=comment_body]', function () {
    mentions.update(this)
  })

  $(document).on('keydown', '[id=comment_body]', function (e) {
    if (mentions.field !== this) return
    if (e.key === 'Escape') {
      mentions.hide()
    } else if (mentions.people.length && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
      e.preventDefault()
      const step = e.key === 'ArrowDown' ? 1 : -1
      mentions.highlight((mentions.selected + step + mentions.people.length) % mentions.people.length)
    } else if (mentions.people.length && (e.key === 'Enter' || e.key === 'Tab')) {
      e.preventDefault()
      mentions.pick(mentions.selected)
    }
  })

  // Moving the caret with the keyboard opens, follows or closes the menu, as clicking does
  $(document).on('keyup', '[id=comment_body]', function (e) {
    if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) mentions.update(this)
  })

  $(document).on('focusout', '[id=comment_body]', function () {
    if (mentions.field === this) mentions.hide()
  })

  $(document).on('focusin', '[id=comment_subject], [id=comment_body]', function () {
    $(this.form).find('.comment-options').show()
  })
})
