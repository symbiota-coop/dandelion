module.exports = {
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
  extends: 'standard',
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
