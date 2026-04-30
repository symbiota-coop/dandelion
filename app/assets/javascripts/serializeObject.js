$.fn.serializeObject = function () {
  const o = {};
  const a = this.serializeArray();

  // Helper to set nested value
  function setNestedValue (obj, path, value) {
    const keys = path.replace(/\]/g, '').split('[')
    let current = obj
    for (let i = 0; i < keys.length - 1; i++) {
      const key = keys[i]
      if (!(key in current)) {
        current[key] = {}
      }
      current = current[key]
    }
    const lastKey = keys[keys.length - 1]
    // Handle multiple values (checkboxes, multi-select)
    if (lastKey in current) {
      if (!Array.isArray(current[lastKey])) {
        current[lastKey] = [current[lastKey]]
      }
      current[lastKey].push(value)
    } else {
      current[lastKey] = value
    }
  }

  // Handle regular form fields
  $.each(a, function () {
    setNestedValue(o, this.name, this.value || '')
  });

  // Handle CKEditor 5 fields (overwrite any existing value from hidden textarea)
  this.find('textarea.wysiwyg').each(function () {
    const editorInstance = this.ckeditorInstance
    if (!editorInstance) return
    const fieldName = this.getAttribute('name') || (editorInstance.sourceElement && editorInstance.sourceElement.getAttribute('name'))
    if (!fieldName) return
    const data = editorInstance.getData()
    // Parse the field name and set directly (overwriting, not appending)
    const keys = fieldName.replace(/\]/g, '').split('[')
    let current = o
    for (let i = 0; i < keys.length - 1; i++) {
      const key = keys[i]
      if (!(key in current)) {
        current[key] = {}
      }
      current = current[key]
    }
    current[keys[keys.length - 1]] = data
  })

  return o;
};

