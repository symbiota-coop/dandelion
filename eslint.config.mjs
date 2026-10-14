import js from '@eslint/js'
import globals from 'globals'
import bootstrap4Leftovers from './config/bootstrap4_leftovers.json' with { type: 'json' }

// Our files and templates' inline scripts are classic scripts sharing the page's global scope: libraries come from the CDN
// (config/frontend_dependencies.rb and layouts/_dependencies.erb, or a page's own <script src>), and some files and
// templates define functions others call
const libraries = [
  'autosize', 'bootstrap', 'Chart', 'ChartDataLabels', 'ClassicEditor', 'Coloris', 'countUp', 'cytoscape', 'DataTable', 'flatpickr',
  'FullCalendar', 'google', 'grecaptcha', 'iframely', 'introJs', 'jsQR', 'markerClusterer', 'Stripe', 'Tribute', 'Typed'
]
const shared = [
  'cssColor', 'DandelionMap', 'destroyLinkFor', 'drawSpanTreeGuides', 'fixedHeaderHeight', 'hideTooltips', 'initQuestionsPreview', 'onContentLoaded',
  'placeAutocomplete', 'renderSearchAutocompleteItem', 'scrollMessageThreadToBottom', 'scrollspy'
]
// Selects string literals and the static parts of template literals whose text matches a regex (esquery's /.../ syntax),
// anywhere or as arguments of the calls a parent selector matches
const strings = (regex, parent) => {
  const [literal, template] = [`Literal[value=${regex}]`, `TemplateLiteral > TemplateElement[value.cooked=${regex}]`]
  return parent ? `${parent} > ${literal}, ${parent} > ${template}` : `${literal}, ${template}`
}

// Bootstrap 4 classes and attributes that Bootstrap 5 renamed or dropped, shared with DesignClasses
const classCalls = 'CallExpression[callee.property.name=/^(addClass|removeClass|toggleClass)$/]'
const bootstrap4 = [
  ...bootstrap4Leftovers.classes.map(({ pattern, use }) => ({
    // In a class attribute, or added, removed or toggled as a class
    selector: [
      strings(`/class=["'][^"']*(?<![\\w-])(?:${pattern})(?![\\w-])/`),
      strings(`/(^|\\s)(?:${pattern})(\\s|$)/`, classCalls),
      strings(`/^(?:${pattern})$/`, "CallExpression[callee.object.property.name='classList']")
    ].join(', '),
    message: `Bootstrap 4 class: in Bootstrap 5, use ${use}.`
  })),
  ...bootstrap4Leftovers.attributes.map(({ pattern, use }) => ({
    selector: strings(`/(?<![\\w-])(?:${pattern})(?![\\w-])/`),
    message: `Bootstrap 4 attribute: in Bootstrap 5, use ${use}.`
  }))
]

// Templates' JavaScript, linted as one script per template: everything else is blanked, so lines and columns stay put.
// Inline <script>s (not src or other types, like JSON) keep their place; event attributes (onclick="...") become
// ;()=>{...}; over their name, quotes and the character after, so each is a function, as in the browser. ERB output becomes __erb, and other ERB
// tags spaces. An attribute's HTML entities (&quot;) are decoded, with the spaces they free at the end of their line, and
// shifts records where, so templateMessages can put columns back
const SCRIPT = /<script\b((?:<%[\s\S]*?%>|[^>])*)>([\s\S]*?)<\/script>/gi
const HANDLER = /(\son[a-z]{2,}\s*=\s*)(["'])((?:<%[\s\S]*?%>|(?!\2)[\s\S])*)\2/gi
const ENTITY = /&(?:[a-z]+|#\d+|#x[\da-f]+);/gi
const ENTITIES = { quot: '"', apos: "'", amp: '&', lt: '<', gt: '>', nbsp: '\u00a0' }
const blank = (text) => text.replace(/[^\n]/g, ' ')
const erbToJs = (text) => text.replace(/<%(==?|#|-)?[\s\S]*?%>/g, (tag, kind) => kind === '=' || kind === '==' ? `__erb${blank(tag.slice(5))}` : blank(tag))
function decode (entity) {
  const name = entity.slice(1, -1).toLowerCase()
  if (name.startsWith('#x')) return String.fromCodePoint(parseInt(name.slice(2), 16))
  if (name.startsWith('#')) return String.fromCodePoint(parseInt(name.slice(1), 10))
  return ENTITIES[name] ?? entity
}
function templateJs (template) {
  const out = blank(template).split('')
  const put = (at, text) => out.splice(at, text.length, ...text)
  const lineStarts = [0, ...[...template.matchAll(/\n/g)].map((newline) => newline.index + 1)]
  const lineOf = (at) => lineStarts.findLastIndex((start) => start <= at)
  const shifts = {} // line => [[from, to, shift]]: 0-based columns, between an entity and the spaces it freed
  const scripts = []
  for (const match of template.matchAll(SCRIPT)) {
    scripts.push([match.index, match.index + match[0].length])
    const attributes = match[1].replace(/<%[\s\S]*?%>/g, '')
    if (/\bsrc\s*=/i.test(attributes) || /\btype\s*=\s*["']?(?!text\/javascript|module)/i.test(attributes)) continue
    put(match.index + match[0].length - '</script>'.length - match[2].length, erbToJs(match[2]))
  }
  for (const match of template.matchAll(HANDLER)) {
    if (scripts.some(([start, end]) => match.index >= start && match.index < end)) continue
    const quote = match.index + match[1].length
    let at = quote + 1
    const code = erbToJs(match[3]).split('\n').map((line, index, lines) => {
      const line0 = lineOf(at)
      const column = at - lineStarts[line0]
      const found = []
      let freed = 0
      const decoded = line.replace(ENTITY, (entity, offset) => {
        const text = decode(entity)
        freed += entity.length - text.length
        found.push([column + offset + entity.length - freed, entity.length - text.length])
        return text
      }) + (index === lines.length - 1 ? '};' : '')
      for (const [from, shift] of found) (shifts[line0] ||= []).push([from, column + decoded.length, shift])
      at += line.length + 1
      return decoded + ' '.repeat(freed)
    }).join('\n')
    put(quote - 5, `;()=>{${code}`)
  }
  return { text: out.join(''), shifts }
}

// Puts back the columns an attribute's decoded entities moved
function templateMessages (messages, shifts) {
  const original = (line, column) => column && column + (shifts[line - 1] || []).reduce((sum, [from, to, shift]) => column - 1 >= from && column - 1 < to ? sum + shift : sum, 0)
  return messages.map((message) => ({ ...message, column: original(message.line, message.column), endColumn: original(message.endLine, message.endColumn) }))
}
const templateShifts = new Map()

const javascript = {
  ecmaVersion: 'latest',
  sourceType: 'script',
  globals: {
    ...globals.browser,
    ...globals.jquery,
    ...Object.fromEntries([...libraries, ...shared].map((name) => [name, 'readonly']))
  }
}

const rules = {
  // Top-level functions are shared with other scripts and inline <script>s, so only flag unused locals
  'no-unused-vars': ['error', { vars: 'local', caughtErrors: 'none' }],
  // Files that define the shared functions above declare them, which is not a redeclaration
  'no-redeclare': ['error', { builtinGlobals: false }],
  'no-empty': ['error', { allowEmptyCatch: true }],
  // Requests use jQuery, not fetch (templates get the same check from .erb_linters/jquery_requests.rb)
  'no-restricted-globals': ['error', { name: 'fetch', message: 'Use jQuery ($.get, $.getJSON, $.post, $.ajax) for requests, not fetch.' }],
  // Rules from the Design section of AGENTS.md (templates get the same checks from .erb_linters/design_classes.rb)
  'no-restricted-syntax': ['error',
    {
      selector: [
        strings('/(^|\\s)d-none(\\s|$)/', classCalls),
        strings('/^d-none$/', "CallExpression[callee.object.property.name='classList']")
      ].join(', '),
      message: 'To show and hide elements, start them hidden with style="display: none" and use .show() / .hide() / .toggle(), not d-none (Bootstrap\'s d-* classes are !important).'
    },
    {
      selector: strings('/(^|[^\\w-])[a-z][a-z-]*-success([^\\w-]|$)/'),
      message: 'Success is the theme colour, so use -primary, not -success.'
    },
    {
      selector: strings('/(^|[^\\w-])badge-(primary|secondary|success|danger|warning|info|light|dark)([^\\w-]|$)/'),
      message: 'Badges are badge text-bg-*; there is no badge-* colour class.'
    },
    {
      // In a class attribute, or added as a class
      selector: [
        strings('/class=["\'][^"\']*(?<![\\w-])label(?![\\w-])/'),
        strings('/(^|\\s)label(\\s|$)/', 'CallExpression[callee.property.name=/^(addClass|toggleClass)$/]')
      ].join(', '),
      message: 'There is no .label class; use badge text-bg-*.'
    },
    {
      selector: strings('/<select(?![^>]*(?<![\\w-])form-select(?![\\w-]))[^>]*>/'),
      message: 'Selects take form-select.'
    },
    ...bootstrap4
  ]
}

export default [
  {
    ignores: ['.claude/**', 'vendor/**', 'app/assets/javascripts/ext/**', 'ckeditor/**', 'node_modules/**']
  },
  js.configs.recommended,
  {
    files: ['app/assets/javascripts/**/*.js'],
    languageOptions: javascript,
    rules
  },
  {
    files: ['app/views/**/*.erb'],
    plugins: {
      erb: {
        processors: {
          scripts: {
            preprocess (template, filename) {
              const { text, shifts } = templateJs(template)
              templateShifts.set(filename, shifts)
              return [{ text, filename: 'scripts.js' }]
            },
            postprocess ([messages], filename) {
              const shifts = templateShifts.get(filename)
              templateShifts.delete(filename)
              return templateMessages(messages, shifts)
            }
          }
        }
      }
    },
    processor: 'erb/scripts'
  },
  {
    files: ['app/views/**/*.erb/*.js'],
    languageOptions: { ...javascript, globals: { ...javascript.globals, __erb: 'readonly' } },
    rules
  }
]
