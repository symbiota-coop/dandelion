(function ($) {
  $.fn.lookup = function (options) {
    return this.each(function () {
      var $el = $(this)
      var initialId = $el.find('option:selected').val()

      // If there's an initial value, fetch its display text from the server (like v3 initSelection)
      if (initialId && initialId !== '') {
        var $option = $el.find('option:selected')
        $option.text('Loading...')
        var data = {}
        data[(options.id_param || $el.attr('name'))] = initialId
        data.rtype = options.rtype
        $.getJSON(options.lookup_url, data, function (response) {
          var result = response.results.filter(function (r) {
            return r.id == initialId
          })[0]
          $option.text(result ? result.text : initialId)
          initSelect2()
        }).fail(function () {
          $option.text(initialId) // Show ID as fallback
          initSelect2()
        })
      } else {
        initSelect2()
      }

      function initSelect2 () {
        $el.select2({
          theme: 'bootstrap4',
          placeholder: options.placeholder,
          allowClear: true,
          minimumInputLength: 1,
          ajax: {
            url: options.lookup_url,
            dataType: 'json',
            delay: 250,
            data: function (params) {
              return {
                q: params.term,
                rtype: options.rtype
              }
            },
            processResults: function (data) {
              return { results: data.results }
            }
          }
        })
      }

      $el.addClass('lookupd')
    })
  }
})(jQuery)
