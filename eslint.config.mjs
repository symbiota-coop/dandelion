import js from '@eslint/js'
import globals from 'globals'

// Our files are classic scripts sharing the page's global scope: libraries come from the CDN
// (config/frontend_dependencies.rb and layouts/_dependencies.erb), and some files define functions others call
const libraries = ['autosize', 'bootstrap', 'ClassicEditor', 'Coloris', 'DataTable', 'google', 'iframely', 'markerClusterer', 'Tribute']
const shared = ['cssColor', 'destroyLinkFor', 'drawSpanTreeGuides', 'fixedHeaderHeight', 'hideTooltips', 'onContentLoaded', 'placeAutocomplete', 'scrollspy']
// Selects string literals and the static parts of template literals whose text matches a regex (esquery's /.../ syntax),
// anywhere or as arguments of the calls a parent selector matches
const strings = (regex, parent) => {
  const [literal, template] = [`Literal[value=${regex}]`, `TemplateLiteral > TemplateElement[value.cooked=${regex}]`]
  return parent ? `${parent} > ${literal}, ${parent} > ${template}` : `${literal}, ${template}`
}

export default [
  {
    ignores: ['.claude/**', 'vendor/**', 'app/assets/javascripts/ext/**', 'ckeditor/**', 'node_modules/**']
  },
  js.configs.recommended,
  {
    files: ['app/assets/javascripts/**/*.js'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'script',
      globals: {
        ...globals.browser,
        ...globals.jquery,
        ...Object.fromEntries([...libraries, ...shared].map((name) => [name, 'readonly']))
      }
    },
    rules: {
      // Top-level functions are shared with other scripts and inline <script>s, so only flag unused locals
      'no-unused-vars': ['error', { vars: 'local', caughtErrors: 'none' }],
      // Files that define the shared functions above declare them, which is not a redeclaration
      'no-redeclare': ['error', { builtinGlobals: false }],
      'no-empty': ['error', { allowEmptyCatch: true }],
      // Rules from the Design section of AGENTS.md (templates get the same checks from .erb_linters/design_classes.rb)
      'no-restricted-syntax': ['error',
        {
          selector: [
            strings('/(^|\\s)d-none(\\s|$)/', 'CallExpression[callee.property.name=/^(addClass|removeClass|toggleClass)$/]'),
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
        }
      ]
    }
  }
]
