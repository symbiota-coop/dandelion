/* eslint-env node */

module.exports = {
  extends: 'eslint:recommended',
  parserOptions: {
    ecmaVersion: 'latest'
  },
  env: {
    browser: true,
    jquery: true
  },
  ignorePatterns: [
    'app/assets/javascripts/ext/**/*.js',
    'app/assets/infinite_admin/**/*.js'
  ]
}
