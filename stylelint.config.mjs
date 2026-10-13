// Rules from the Design section of AGENTS.md, for our stylesheets in app/assets/stylesheets. No shared config:
// only these rules, so it checks the design tokens rather than formatting
export default {
  ignoreFiles: [
    'app/assets/stylesheets/bootstrap5.css', // compiled vendor CSS: change bootstrap5.scss instead
    // Inlined into emails, which can't use custom properties, so they keep their own colours
    'app/assets/stylesheets/email.css',
    'app/assets/stylesheets/event_details.css'
  ],
  rules: {
    // Colours come from tokens: a hex value only where a token is defined (--color-x: #...)
    'declaration-property-value-disallowed-list': [
      { '/^(?!--)/': ['/#[0-9a-fA-F]{3,8}\\b/'] },
      { message: 'Use a colour token (--theme-*, --color-*, --bs-gray-*...), not a hex value' }
    ],
    // Spacing comes from the scale (--space-* in CSS) and other sizes are in rem or em
    'declaration-property-unit-disallowed-list': [
      { '/^(margin|padding|gap|row-gap|column-gap|inset)/': ['px'], 'font-size': ['px'] },
      { message: 'Use --space-* for spacing and rem or em for font sizes, not px' }
    ]
  }
}
