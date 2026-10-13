import js from '@eslint/js'
import globals from 'globals'

// Our files are classic scripts sharing the page's global scope: libraries come from the CDN
// (config/frontend_dependencies.rb and layouts/_dependencies.erb), and some files define functions others call
const libraries = ['autosize', 'bootstrap', 'ClassicEditor', 'Coloris', 'DataTable', 'google', 'iframely', 'markerClusterer', 'Tribute']
const shared = ['cssColor', 'destroyLinkFor', 'drawSpanTreeGuides', 'fixedHeaderHeight', 'hideTooltips', 'onContentLoaded', 'placeAutocomplete', 'scrollspy']

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
      'no-empty': ['error', { allowEmptyCatch: true }]
    }
  }
]
