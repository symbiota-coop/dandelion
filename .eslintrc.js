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
