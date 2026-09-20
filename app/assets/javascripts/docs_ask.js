/* global $, marked, DOMPurify */

(function () {
  var POLL_MS = 30
  var TIMEOUT_MS = 120000
  var REPO = 'symbiota-coop/dandelion'
  var HOST = 'https://deepwiki.com'
  var WIKI_URL = HOST + '/' + REPO
  var USER_FOCUS = 'This question is from a Dandelion organiser or attendee using the product, not a developer reading the code. Answer in product terms: what to click and what happens. Never mention file names, file paths, partials, models, routes, helpers, class names, or line numbers. Do not include a Notes section. Do not include a "Wiki pages you might want to explore" section.'

  var root = document.getElementById('deepwiki-answer')
  if (!root || root.getAttribute('data-deepwiki-done') === 'true') return

  var MCP_URL = root.getAttribute('data-deepwiki-mcp') || 'https://mcp.deepwiki.com/mcp'
  var question = (root.getAttribute('data-deepwiki-question') || '').trim()
  if (!question) return

  var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  var targetHtml = ''
  var targetChars = 0
  var shownChars = 0
  var done = false
  var failed = false
  var tickTimer = null
  var timeoutTimer = null

  function textLength (el) {
    return el ? (el.textContent || '').length : 0
  }

  function parseHtml (html) {
    var div = document.createElement('div')
    div.innerHTML = html || ''
    return div
  }

  function eachChild (node, fn) {
    var children = Array.prototype.slice.call(node.childNodes)
    for (var i = 0; i < children.length; i++) fn(children[i])
  }

  function htmlTextLength (html) {
    return textLength(parseHtml(html))
  }

  function htmlUpTo (html, maxChars) {
    var div = parseHtml(html)
    var left = maxChars

    var walk = function (node) {
      if (left <= 0) {
        if (node.parentNode) node.parentNode.removeChild(node)
        return
      }
      if (node.nodeType === 3) {
        if (node.data.length > left) node.data = node.data.slice(0, left)
        left -= node.data.length
        return
      }
      if (node.nodeType === 1) eachChild(node, walk)
    }

    eachChild(div, walk)
    return div.innerHTML
  }

  function sourceUrl () {
    return $('#deepwiki-source a').attr('href') || WIKI_URL
  }

  function setSourceUrl (href) {
    if (!href) return
    $('#deepwiki-source a').attr('href', href)
  }

  function cacheKey () {
    return 'deepwiki:' + question
  }

  function readCache () {
    try {
      var raw = window.sessionStorage.getItem(cacheKey())
      return raw ? JSON.parse(raw) : null
    } catch (e) {
      return null
    }
  }

  function writeCache (data) {
    try {
      window.sessionStorage.setItem(cacheKey(), JSON.stringify(data))
    } catch (e) {}
  }

  function separateLists (markdown) {
    var list = /^\s*(?:[-*+]|\d+\.)\s/
    return markdown.split(/(```[\s\S]*?```)/).map(function (part) {
      if (part.slice(0, 3) === '```') return part
      return part.replace(/^(?!\s*(?:[-*+]|\d+\.)\s)(\S.*)\n(?=\s*(?:[-*+]|\d+\.)\s)/gm, '$1\n\n')
    }).join('')
  }

  function cleanMarkdown (markdown) {
    return separateLists(
      markdown
        .replace(/^\s*## Answer\s*/i, '')
        .replace(/\n*Wiki pages you might want to explore:[\s\S]*$/i, '')
        .replace(/\n*View this search on DeepWiki:\s*https:\/\/deepwiki\.com\/search\/\S+/i, '')
        .replace(/\]\(\/wiki\/([^)#]+)(?:#([^)]+))?\)/g, function (_, path, hash) {
          return '](' + HOST + '/' + path + (hash ? '/' + hash : '') + ')'
        })
        .replace('](/' + REPO.split('/')[0] + '/', '](' + HOST + '/' + REPO.split('/')[0] + '/')
        .replace(new RegExp('\\[([^\\]]+?) \\(' + REPO.replace('/', '\\/') + '\\)\\]', 'g'), '[$1]')
        .replace(/ +([.,;:])/g, '$1')
        .trim()
    )
  }

  function extractSourceUrl (text) {
    var match = String(text || '').match(/View this search on DeepWiki:\s*(https:\/\/deepwiki\.com\/search\/[^\s]+)/i)
    return match ? match[1] : ''
  }

  function answerHtml (markdown) {
    if (!markdown || !window.marked || !window.DOMPurify) return ''

    var html = marked.parse(markdown, { gfm: true })
    var clean = DOMPurify.sanitize(html, { ADD_ATTR: ['target'] })
    var div = parseHtml(clean)

    Array.prototype.forEach.call(div.querySelectorAll('table'), function (table) {
      table.className = ['table', 'table-bordered', table.className].filter(Boolean).join(' ')
      var wrap = document.createElement('div')
      wrap.className = 'doc-table-wrap'
      table.parentNode.insertBefore(wrap, table)
      wrap.appendChild(table)
    })
    Array.prototype.forEach.call(div.querySelectorAll('a[href]'), function (a) {
      var href = a.getAttribute('href') || ''
      if (/^https?:\/\//i.test(href)) {
        a.setAttribute('target', '_blank')
        a.setAttribute('rel', 'noopener noreferrer')
      }
    })
    return div.innerHTML
  }

  function parseSse (text) {
    var blocks = []
    var current = []
    String(text || '').split(/\r?\n/).forEach(function (line) {
      if (line.indexOf('data:') === 0) current.push(line.replace(/^data:\s?/, ''))
      else if (!line && current.length) {
        blocks.push(current.join('\n'))
        current = []
      }
    })
    if (current.length) blocks.push(current.join('\n'))
    if (!blocks.length) return JSON.parse(text)
    return JSON.parse(blocks[blocks.length - 1])
  }

  function mcpText (payload) {
    if (payload.error) throw new Error(payload.error.message || 'DeepWiki error')
    var result = payload.result || {}
    if (result.isError) throw new Error('DeepWiki error')
    var content = result.content
    if (Array.isArray(content)) {
      return content.map(function (item) {
        return item && item.type === 'text' ? item.text : ''
      }).join('')
    }
    if (result.structuredContent && result.structuredContent.result) return result.structuredContent.result
    return ''
  }

  function render () {
    if (failed) {
      var href = sourceUrl()
      root.innerHTML = '<div class="alert alert-danger">DeepWiki couldn\'t finish this answer. <a target="_blank" rel="noopener noreferrer" href="' + href + '">Try it on DeepWiki</a>.</div>'
      return
    }
    if (!targetHtml) return

    var html = (done && shownChars >= targetChars) || reduceMotion ? targetHtml : htmlUpTo(targetHtml, shownChars)
    root.innerHTML = '<div class="docs-deepwiki-answer">' + html + '</div>'
  }

  function step () {
    if (failed) return
    if (shownChars < targetChars) {
      var behind = targetChars - shownChars
      var jump = reduceMotion ? behind : (behind > 400 ? 28 : behind > 80 ? 10 : 3)
      shownChars = Math.min(targetChars, shownChars + jump)
      render()
    } else if (done) {
      render()
      stop()
    }
  }

  function fail () {
    if (done) return
    failed = true
    render()
    stop()
  }

  function finish (html, href) {
    targetHtml = html
    targetChars = htmlTextLength(targetHtml)
    if (reduceMotion) shownChars = targetChars
    setSourceUrl(href)
    done = true
    if (targetHtml) render()
    else stop()
  }

  function stop () {
    if (tickTimer) window.clearInterval(tickTimer)
    if (timeoutTimer) window.clearTimeout(timeoutTimer)
    tickTimer = null
    timeoutTimer = null
    root.setAttribute('data-deepwiki-done', 'true')
    if (done) $('#deepwiki-source').removeClass('d-none')
    $('#deepwiki-ask').removeClass('d-none')
  }

  function ask () {
    var cached = readCache()
    if (cached && cached.html) {
      finish(cached.html, cached.source_url)
      return
    }

    fetch(MCP_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json, text/event-stream'
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: {
          name: 'ask_question',
          arguments: {
            repoName: REPO,
            question: '<relevant_context>' + USER_FOCUS + '</relevant_context>' + question
          }
        }
      })
    }).then(function (res) {
      if (!res.ok) throw new Error('bad status')
      return res.text()
    }).then(function (body) {
      if (failed) return
      var text = mcpText(parseSse(body))
      if (!text.trim()) throw new Error('empty')
      var href = extractSourceUrl(text)
      var html = answerHtml(cleanMarkdown(text))
      if (!html) throw new Error('empty html')
      writeCache({ html: html, source_url: href })
      finish(html, href)
    }).catch(fail)
  }

  tickTimer = window.setInterval(step, POLL_MS)
  timeoutTimer = window.setTimeout(fail, TIMEOUT_MS)
  ask()
})()
