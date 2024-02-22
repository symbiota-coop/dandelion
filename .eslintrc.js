/* eslint-env node */

module.exports = {
  ignorePatterns: [
    'app/assets/javascripts/ext/**/*.js',
    'app/assets/infinite_admin/**/*.js'
  ],
  env: {
    browser: true,
    es2021: true,
    jquery: true
  },
  globals: {
    Stripe: true,
    ethereum: true,
    Web3: true,
    Tribute: true,
    iframely: true,
    autosize: true,
    hljs: true,
    Pace: true,
    ClassicEditor: true
  },
  extends: 'eslint:recommended',
  overrides: [
  ],
  parserOptions: {
    ecmaVersion: 'latest'
  },
  rules: {
    camelcase: 'off',
    eqeqeq: 'off'
  }
}
