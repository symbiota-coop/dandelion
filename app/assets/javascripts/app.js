/*global $*/

var LOADING = '<i class="my-3 fa fa-spin fa-circle-o-notch"></i>'

function nl2br(str) {
  return str.replace(/(?:\r\n|\r|\n)/g, '<br>');
}

function br2nl(str) {
  return str.replace(/<br>/g, "\r\n");
}

jQuery.fn.dataTable.Api.register('sum()', function () {
  return this.flatten().reduce(function (a, b) {
    var x = parseFloat(a) || 0;
    var y = parseFloat($(b).attr('data-sort')) || 0;
    return x + y
  }, 0);
});

$.fn.serializeObject = function () {
  var o = {};
  var a = this.serializeArray();
  $.each(a, function () {
    if (o[this.name]) {
      if (!o[this.name].push) {
        o[this.name] = [o[this.name]];
      }
      o[this.name].push(this.value || '');
    } else {
      o[this.name] = this.value || '';
    }
  });
  return o;
};

$(function () {

  function ajaxCompleted() {

    $('input[type=file]').change(function () {
      if (this.files.length > 0 && this.files[0].size > 5e6) {
        alert('That file is too large, the maximum file size is 5MB. Please resize it before uploading.')
        $(this).val('')
      }
    })

    $('[data-confirm], [href$="destroy"]').not('[data-confirm-registered]').attr('data-confirm-registered', 'true').each(function () {
      $(this).click(function () {
        $(this).removeClass('no-trigger')

        var message = $(this).data('confirm') || 'Are you sure?';
        if (!confirm(message)) {
          $(this).addClass('no-trigger')
          return false
        }
      })
    });

    $('form.add-placeholders label[for]').not('[data-placeholders-added]').attr('data-placeholders-added', true).each(function () {
      var input = $(this).next().children().first()
      if (!$(input).attr('placeholder'))
        $(input).attr('placeholder', $.trim($(this).text()))
    });

    // use classes here, because flatpickr copies classes (resulting in multiple calls) but not data attributes
    $('.datepicker').not('.flatpickr-registered').addClass('flatpickr-registered').flatpickr({
      altInput: true,
      altFormat: 'Y-m-d'
    });
    $('.datetimepicker').not('.flatpickr-registered').addClass('flatpickr-registered').flatpickr({
      altInput: true,
      altFormat: 'J F Y, H:i',
      enableTime: true,
      time_24hr: true
    });

    $('[id=comment_body]').not('[data-tributed]').attr('data-tributed', true).each(function () {
      var tribute = new Tribute({
        values: function (text, callback) {
          $.get('/network?q=' + text, function (data) {
            callback(data)
          })
        },
        selectTemplate: function (item) {
          return '[@' + item.original.key + '](@' + item.original.value + ')';
        },
      })
      tribute.attach(this);
    })

    $('.tagify').not('[data-tagified]').attr('data-tagified', true).each(function () {
      $(this).html($(this).html().replace(/\[@([\w\s'-\.]+)\]\(@(\w+)\)/g, '<a href="/u/$2">$1</a>'));
    })

    $('[id=comment_subject], [id=comment_body]').not('[data-show-comment-options-on-focus]').attr('data-show-comment-options-on-focus', true).focus(function () {
      $(this.form).find('.comment-options').removeClass('d-none')
    })

    $('[data-toggle="tooltip"]').not('[data-tooltipd]').attr('data-tooltipd', true).tooltip({
      html: true,
      title: function () {
        if ($(this).attr('title').length > 0)
          return $(this).attr('title')
        else
          return $(this).next('span').html()
      }
    })

    $('.block').not('[data-block-hover]').attr('data-block-hover', true).hover(
      function () {
        $('.block-edit', this).show()
      },
      function () {
        $('.block-edit', this).hide()
      }
    )

    $("abbr.timeago").not('[data-timeago-done]').attr('data-timeago-done', true).timeago()

    $('[data-account-username]').not('#modal [data-account-username]').not('[data-modalized]').attr('data-modalized', true).click(function () {
      $('#modal .modal-content').load('/u/' + $(this).attr('data-account-username'), function () {
        $('#modal').modal('show');
        $('[data-toggle="tooltip"]').tooltip('hide');
      });
    })

    $('.linkify').not('[data-linkified]').attr('data-linkified', true).linkify();

    $('.compact-urls').not('[data-compact-urls]').attr('data-compact-urls', true).each(function () {
      $(this).html($(this).html().replace(/<a (.*)>(.*)<\/a>/, function (match, p1, p2) {
        parts = p2.split('/')
        if (p2.match(/^(http|https):\/\//) && p2.length > 50 && parts.length > 3) {
          t = parts[0] + '//' + parts[2] + '/...'
        } else {
          t = p2
        }
        return '<a ' + p1 + '>' + t + '</a>'
      }))
    })

    $('.nl2br').not('[data-nl2br]').attr('data-nl2br', true).each(function () {
      $(this).html(nl2br($(this).html()))
    })

    $('textarea[id=comment_body], #account_client_note, textarea.autosize').not('[data-autosized]').attr('data-autosized', true).each(function () {
      autosize(this)
    })

    $('oembed[url]').not('[data-embedded]').attr('data-embedded', true).each(function () {
      iframely.load(this, $(this).attr('url'));
      if ($(this).parent().is('figure.media'))
        $(this).parent().removeClass('media')
    });

    $('.links-blank').not('[data-links-blank-done]').attr('data-links-blank-done', true).each(function () {
      $('a[href^=http]', this).attr('target', '_blank')
    })

  }

  $(document).ajaxComplete(function () {
    ajaxCompleted()
  });
  ajaxCompleted()







  hljs.highlightAll();

  $('input[type=hidden].lookup').each(function () {
    $(this).lookup({
      lookup_url: $(this).attr('data-lookup-url'),
      placeholder: $(this).attr('placeholder'),
      id_param: 'id'
    });
  });

  $('[data-upload-url]').click(function () {
    var form = $('<form action="' + $(this).attr('data-upload-url') + '" method="post" enctype="multipart/form-data"><input style="display: none" type="file" name="upload"></form>')
    form.insertAfter(this)
    form.find('input').click().change(function () {
      this.form.submit()
    })
  })

  $('input[type=text].slug').each(function () {
    var slug = $(this);
    var start_length = slug.val().length;
    var pos = $.inArray(this, $('input', this.form)) - 1;
    var title = $($('input', this.form).get(pos));
    slug.focus(function () {
      slug.data('focus', true);
    });
    title.keyup(function () {
      if (start_length == 0 && slug.data('focus') != true)
        slug.val(title.val().toLowerCase().replace(/ /g, '-').replace(/[^a-z0-9\-]/g, ''));
    });
  });

  $('input[type=text].shorturl').each(function () {
    var input = $(this)
    var stem = $(this).prev()
    var link = $(this).next()
    link.attr('data-toggle', 'tooltip')
    link.attr('title', 'Click to copy')
    link.click(function () {
      navigator.clipboard.writeText(stem.text() + input.val());
      link.attr('title', 'Copied!')
      link.tooltip('dispose').tooltip().tooltip('show');
      return false
    })
    input.keydown(function () {
      link.hide()
    });
  });

  $(document).on('click', 'a.popup', function (e) {
    window.open(this.href, null, 'scrollbars=yes,width=600,height=600,left=150,top=150').focus();
    return false;
  });

  if (window.location.hash.startsWith('#photo-'))
    $("[data-target='" + window.location.hash + "']").click()

  $('textarea.wysiwyg').each(function () {
    var textarea = this
    ClassicEditor.create(textarea, {
      simpleUpload: {
        uploadUrl: '/upload'
      },
      mediaEmbed: {
        removeProviders: ['facebook', 'twitter', 'instagram', 'googleMaps', 'flickr']
      }
    }).catch(error => {
      console.error(error);
    });
  });

  $('form.submitOnChange').each(function () {
    $('select, .flatpickr-input, input[type=checkbox]', this).change(function () {
      $(this.form).submit()
    })
  })

  $('.labelize').each(function () {
    $('div.checkbox', this).each(function () {
      var div = this
      $(div).hide()
      var button = $('<a href="javascript:;" class="d-inline-block mb-1 mr-1"><span class="label label-outline-primary">' + $(this).find('label').text() + '</span></a>').insertAfter(this);
      if ($('input[type=checkbox]:checked', div).length > 0)
        $('span', button).removeClass('label-outline-primary').addClass('label-primary')
      $(button).click(function () {
        if ($('input[type=checkbox]:checked', div).length > 0) {
          console.log('unchecking')
          $('input[type=checkbox]', div).prop('checked', false)
          $('span', button).removeClass('label-primary').addClass('label-outline-primary')
        } else {
          console.log('checking')
          $('input[type=checkbox]', div).prop('checked', true)
          $('span', button).removeClass('label-outline-primary').addClass('label-primary')
        }
      })
    })
  })

  $(window).on('beforeunload', function () {
    if ($('#page-container').hasClass('page-sidebar-toggled') && $(window).width() < 768) {
      $('.pace-activity').css('border-top-color', 'white').css('border-left-color', 'white')
    }
    $('.pace-progress').hide()
    $('.pace-inactive').show()
  });

  Pace.stop();

});
