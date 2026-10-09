// The reverse of $.param: turns a query string into an object, so a=1&a=2 gives { a: ['1', '2'] },
// a[]=1&a[]=2 gives { a: ['1', '2'] }, a[0]=1 gives { a: ['1'] } and a[b][c]=1 gives { a: { b: { c: '1' } } }
$.deparam = function (query) {
  const obj = {}

  new URLSearchParams(query).forEach(function (value, name) {
    const match = name.match(/^([^[\]]+)((?:\[[^[\]]*\])+)$/)
    const keys = match ? [match[1]].concat(match[2].slice(1, -1).split('][')) : [name]
    if (keys.some(key => ['__proto__', 'constructor', 'prototype'].includes(key))) return

    if (keys.length === 1) {
      if (Array.isArray(obj[name])) {
        obj[name].push(value)
      } else if (Object.hasOwn(obj, name)) {
        obj[name] = [obj[name], value]
      } else {
        obj[name] = value
      }
      return
    }

    let current = obj
    keys.forEach(function (key, i) {
      if (key === '' && Array.isArray(current)) key = current.length
      if (i === keys.length - 1) {
        current[key] = value
      } else {
        // The next key decides what this level holds: [] or [0] make an array, [b] an object
        if (typeof current[key] !== 'object') current[key] = isNaN(keys[i + 1]) ? {} : []
        current = current[key]
      }
    })
  })

  return obj
}
