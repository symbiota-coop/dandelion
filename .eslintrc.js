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
  ],
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
  }
}
