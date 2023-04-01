(function ($) {
  $.fn.lookup = function (options) {
    const settings = { lookup_url: null, placeholder: null, rtype: null, id_param: null }

    return this.each(function () {
      if (options) {
        $.extend(settings, options)
      }

      $(this).select2({
        placeholder: options.placeholder,
        allowClear: true,
        minimumInputLength: 1,
        width: '100%',
        ajax: {
          url: options.lookup_url,
          dataType: 'json',
          data: function (term) {
            return {
              q: term,
              rtype: options.rtype
            }
          },
          results: function (data) {
            return { results: data.results }
          }
        },
        initSelection: function (element, callback) {
          const id = $(element).val()
          if (id !== '') {
            const data = {}
            data[(options.id_param || $(element).attr('name'))] = id
            data.rtype = options.rtype
            $.getJSON(options.lookup_url, data, function (data) {
              const result = data.results.filter(function (result) {
                return result.id == id
              })[0]
              callback(result)
            })
          }
        }
      })

      $(this).addClass('lookupd')
    })
  }
})(jQuery)
