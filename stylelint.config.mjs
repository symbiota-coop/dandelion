import postcss from 'postcss'

// Rules from the Design section of AGENTS.md, for our stylesheets in app/assets/stylesheets and the CSS in templates. No
// shared config: only these rules, so it checks the design tokens rather than formatting

// Templates' CSS, parsed as one stylesheet per template: everything else is blanked, so lines and columns stay put.
// <style> blocks keep their place; style="..." attributes become a{...} over their = and quotes. ERB output in a value
// becomes __erb, and other ERB tags (or output standing for a whole declaration or part of a selector) spaces. An ERB
// comment that disables a rule (<%# stylelint-disable-next-line rule -- reason %>) becomes a CSS comment, for CSS in Ruby
const STYLE = /<style\b((?:<%[\s\S]*?%>|[^>])*)>([\s\S]*?)<\/style>/gi
const STYLE_ATTRIBUTE = /(\sstyle\s*=\s*)(["'])((?:<%[\s\S]*?%>|(?!\2)[\s\S])*)\2/gi
const blank = (text) => text.replace(/[^\n]/g, ' ')
const inValue = (css) => css.slice(Math.max(css.lastIndexOf(';'), css.lastIndexOf('{'), css.lastIndexOf('}')) + 1).includes(':')
const erbToCss = (text) => text.replace(/<%(==?|#|-)?[\s\S]*?%>/g, (tag, kind, offset, css) =>
  (kind === '=' || kind === '==') && inValue(css.slice(0, offset)) ? `__erb${blank(tag.slice(5))}` : blank(tag))
function templateCss (template) {
  const out = blank(template).split('')
  const put = (at, text) => out.splice(at, text.length, ...text)
  const styles = []
  for (const match of template.matchAll(STYLE)) {
    styles.push([match.index, match.index + match[0].length])
    put(match.index + match[0].length - '</style>'.length - match[2].length, erbToCss(match[2]))
  }
  for (const match of template.matchAll(STYLE_ATTRIBUTE)) {
    if (styles.some(([start, end]) => match.index >= start && match.index < end)) continue
    put(match.index + match[1].length - 1, `a{${erbToCss(match[3])}}`)
  }
  for (const match of template.matchAll(/<%#(\s*stylelint-[\s\S]*?)%>/g)) put(match.index, `/* ${match[1].slice(1)}*/`)
  return out.join('')
}
const templateSyntax = { parse: (template, options) => postcss.parse(templateCss(template), options), stringify: postcss.stringify }

export default {
  ignoreFiles: [
    'app/assets/stylesheets/bootstrap5.css' // compiled vendor CSS: change bootstrap5.scss instead
  ],
  rules: {
    'declaration-property-value-disallowed-list': [
      {
        // Colours come from tokens: a hex or rgb()/hsl()... of numbers only where a token is defined (--color-x: #...).
        // Translucent black and white are rgba(var(--bs-black-rgb), a), which this allows
        '/^(?!--)/': ['/#[0-9a-fA-F]{3,8}\\b/', '/\\b(rgb|hsl|hwb|lab|lch|oklab|oklch)a?\\(\\s*[\\d.]/'],
        // Radii come from Bootstrap's variables (--bs-border-radius*), or are 0, 50% or inherit
        '/radius$/': ['/\\d(px|r?em)\\b/'],
        // A blurred shadow is an elevation, so it's one of Bootstrap's: unblurred rings (the focus ring, overlays) are fine
        '/^(box|text)-shadow$/': ['/(^|,)\\s*(inset\\s+)?-?[\\d.]+[a-z]*\\s+-?[\\d.]+[a-z]*\\s+(\\d*\\.)?\\d*[1-9]/'],
        // Motion: transitions animate only colours, shadows, masks, opacity, translate and rotate (nothing scales or grows),
        // over --transition-fast or --transition-enter, and only loading indicators loop
        '/^transition(-property|-duration)?$/': [
          '/(^|,)\\s*(all|transform|scale|width|height|max-height|min-height|top|right|bottom|left|inset|margin[\\w-]*|padding[\\w-]*)(\\s|,|$)/',
          '/(^|[\\s,])\\d*\\.?\\d+m?s(\\s|,|$)/'
        ],
        '/^animation(-iteration-count)?$/': ['/\\binfinite\\b/']
      },
      {
        message: (property, value) => {
          if (property.startsWith('animation')) return 'Only loading indicators (.bi-spin, .placeholder-glow) loop'
          if (property.startsWith('transition')) {
            return /(^|[\s,])\d*\.?\d+m?s(\s|,|$)/.test(value)
              ? 'Transitions take --transition-fast or --transition-enter, not a duration of their own'
              : 'Animate only colours, shadows, masks, opacity, translate and rotate: not all, transform, scale or sizes'
          }
          if (property.endsWith('radius')) return 'Use a radius token (--bs-border-radius, -sm, -lg, -xl, -pill), 0, 50% or inherit'
          if (property.endsWith('shadow')) return 'A shadow with blur is an elevation: use --bs-box-shadow-sm, --bs-box-shadow or --bs-box-shadow-lg'
          return 'Use a colour token (--theme-*, --color-*, --bs-gray-*...), not a hex or rgb() value'
        }
      }
    ],
    'color-named': ['never', { ignoreProperties: ['/^--/'], message: 'Use a colour token (--bs-white, --bs-black...), not a named colour' }],
    // Spacing comes from the scale (--space-* in CSS) and other sizes are in rem or em
    'declaration-property-unit-disallowed-list': [
      { '/^(margin|padding|gap|row-gap|column-gap|inset)/': ['px'], '/^(top|right|bottom|left)$/': ['px'], 'font-size': ['px'] },
      { message: 'Use --space-* for spacing and insets and rem or em for font sizes, not px' }
    ]
  },
  overrides: [
    {
      files: ['app/views/**/*.erb'],
      customSyntax: templateSyntax
    },
    {
      // Inlined into emails, or emails themselves, which can't use custom properties, so they keep their own colours and sizes
      files: ['app/assets/stylesheets/email.css', 'app/assets/stylesheets/event_details.css', 'app/views/emails/**/*.erb', 'app/views/layouts/{email,pmail}.erb'],
      rules: {
        'declaration-property-value-disallowed-list': [
          { '/.*/': ['/var\\(/'] },
          { message: 'This file is inlined into emails, which can\'t use custom properties (var(--x))' }
        ],
        'color-named': null,
        'declaration-property-unit-disallowed-list': null
      }
    }
  ]
}
