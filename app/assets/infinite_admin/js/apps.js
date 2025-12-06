/* 01. Handle Scrollbar
 ------------------------------------------------ */
var handleSlimScroll = function () {
  "use strict";
  $('[data-scrollbar=true]').each(function () {
    generateSlimScroll($(this));
  });
};
var generateSlimScroll = function (element) {
  if ($(element).attr('data-init')) {
    return;
  }
  var dataHeight = $(element).attr('data-height');
  dataHeight = (!dataHeight) ? $(element).height() : dataHeight;

  var scrollBarOption = {
    height: dataHeight,
    alwaysVisible: false
  };
  if (/Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)) {
    $(element).css('height', dataHeight);
    $(element).css('overflow-x', 'scroll');
  } else {
    $(element).slimScroll(scrollBarOption);
    $(element).closest('.slimScrollDiv').find('.slimScrollBar').hide();
  }
  $(element).attr('data-init', true);
};


/* 02. Handle Header Search Bar
 ------------------------------------------------ */
var handleHeaderSearchBar = function () {
  $(document).on('click', '[data-toggle="search-bar"]', function (e) {
    e.preventDefault();

    $('.header-search-bar').addClass('active');
    $('body').append('<a href="javascript:;" data-dismiss="search-bar" id="search-bar-backdrop" class="search-bar-backdrop"></a>');
    $('#search-bar-backdrop').fadeIn(200);
    setTimeout(function () {
      $('#header-search').focus();
    }, 200);
  });
  $(document).on('click', '[data-dismiss="search-bar"]', function (e) {
    e.preventDefault();

    $('.header-search-bar').addClass('inactive');
    setTimeout(function () {
      $('.header-search-bar').removeClass('active inactive');
    }, 200);
    $('#search-bar-backdrop').fadeOut(function () {
      $(this).remove();
    });
  });
  $('#header-search').autocomplete({
    html: true,
    source: '/search',
    minLength: 3,
    open: function (event, ui) {
      $(this).autocomplete("widget").css({ "width": ($(this).width() + "px") })
    },
    search: function () {
      $('.header-search-bar .right-icon').html('<i class="bi bi-spin bi-slash-lg"></i>')
    },
    response: function () {
      $('.header-search-bar .right-icon').html('<i class="bi bi-x-lg"></i>')
    },
    create: function () {
      $(this).data('ui-autocomplete')._renderItem = function (ul, item) {
        return $('<li>')
          .append($('<a>').html(item.label).attr('data-value', item.value))
          .appendTo(ul);
      };
    },
    select: function (event, ui) {
      $('#header-search').closest('form').submit();
      return false
    },
  }).on('focus', function () {
    $(this).autocomplete('search');
  });
  $('#header-search').autocomplete('widget').addClass('search-bar-autocomplete animated fadeIn');

  $(document).on('click', '.search-bar-autocomplete a', function (e) {
    var value = $(this).attr('data-value');
    $('#header-search').val(value);
    $('#header-search').closest('form').submit();
  });
};


/* 03. Handle Sidebar Menu
 ------------------------------------------------ */
var handleSidebarMenu = function () {
  "use strict";
  $('.sidebar .nav > .has-sub > a').click(function () {
    var target = $(this).next('.sub-menu');
    var otherMenu = '.sidebar .nav > li.has-sub > .sub-menu';

    if ($('.page-sidebar-minified').length === 0) {
      $(otherMenu).not(target).slideUp(250, function () {
        $(this).closest('li').removeClass('expand');
      });
      $(target).slideToggle(250, function () {
        var targetLi = $(this).closest('li');
        if ($(targetLi).hasClass('expand')) {
          $(targetLi).removeClass('expand');
        } else {
          $(targetLi).addClass('expand');
        }
      });
    }
  });
  $('.sidebar .nav > .has-sub .sub-menu li.has-sub > a').click(function () {
    if ($('.page-sidebar-minified').length === 0) {
      var target = $(this).next('.sub-menu');
      $(target).slideToggle(250);
    }
  });
  $(document).on('click', '[data-click="sidebar-toggled"]', function (e) {
    e.preventDefault();

    var targetContainer = '#page-container';
    var targetClass = 'page-sidebar-toggled';

    if ($(targetContainer).hasClass(targetClass)) {
      $(targetContainer).removeClass(targetClass);
      $(this).removeClass('active');
    } else {
      $(targetContainer).addClass(targetClass);
      $(this).addClass('active');
    }
  });
};


/* 04. Handle Sidebar Minify
 ------------------------------------------------ */
var handleSidebarMinify = function () {
  $('[data-click="sidebar-minify"]').click(function (e) {
    e.preventDefault();

    var targetElm = '#page-container';
    var targetClass = 'page-sidebar-minified';

    if ($(targetElm).hasClass(targetClass)) {
      $(targetElm).removeClass(targetClass);
    } else {
      $(targetElm).addClass(targetClass);
    }
  });
};


/* 05. Handle Sidebar Scroll Memory
 ------------------------------------------------ */
var handleSidebarScrollMemory = function () {
  if (!(/Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent))) {
    $('.sidebar [data-scrollbar="true"]').slimScroll().bind('slimscrolling', function (e, pos) {
      localStorage.setItem('sidebarScrollPosition', pos + 'px');
    });

    var defaultScroll = localStorage.getItem('sidebarScrollPosition');
    if (defaultScroll) {
      $('.sidebar [data-scrollbar="true"]').slimScroll({ scrollTo: defaultScroll });
    }
  }
};


/* 06. Handle Sidebar Minify Float Menu
 ------------------------------------------------ */
var floatSubMenuTimeout;
var targetFloatMenu;
var handleMouseoverFloatSubMenu = function (elm) {
  clearTimeout(floatSubMenuTimeout);
};
var handleMouseoutFloatSubMenu = function (elm) {
  floatSubMenuTimeout = setTimeout(function () {
    $('.float-sub-menu').remove();
  }, 250);
};
var handleSidebarMinifyFloatMenu = function () {
  $(document).on('click', '.float-sub-menu li.has-sub > a', function () {
    var target = $(this).next('.sub-menu');
    $(target).slideToggle(250, function () {
      var targetMenu = $('.float-sub-menu');
      var targetHeight = $(targetMenu).height() + 20;
      var targetOffset = $(targetMenu).offset();
      var targetTop = $(targetMenu).attr('data-offset-top');
      var windowHeight = $(window).height();
      if ((windowHeight - targetTop) > targetHeight) {
        $('.float-sub-menu').css({
          'top': targetTop,
          'bottom': 'auto',
          'overflow': 'initial'
        });
      } else {
        $('.float-sub-menu').css({
          'bottom': 0,
          'overflow': 'scroll'
        });
      }
    });
  });
  $('.sidebar .nav > li.has-sub > a').hover(function () {
    if (!$('#page-container').hasClass('page-sidebar-minified')) {
      return;
    }
    clearTimeout(floatSubMenuTimeout);

    var targetMenu = $(this).closest('li').find('.sub-menu').first();
    if (targetFloatMenu == this) {
      return false;
    } else {
      targetFloatMenu = this;
    }
    var targetMenuHtml = $(targetMenu).html();

    if (targetMenuHtml) {
      var targetHeight = $(targetMenu).height() + 20;
      var targetOffset = $(this).offset();
      var targetTop = targetOffset.top - $(window).scrollTop();
      var targetLeft = (!$('#page-container').hasClass('page-sidebar-right')) ? 60 : 'auto';
      var targetRight = (!$('#page-container').hasClass('page-sidebar-right')) ? 'auto' : 60;
      var windowHeight = $(window).height();

      if ($('.float-sub-menu').length == 0) {
        targetMenuHtml = '<ul class="float-sub-menu" data-offset-top="' + targetTop + '" onmouseover="handleMouseoverFloatSubMenu(this)" onmouseout="handleMouseoutFloatSubMenu(this)">' + targetMenuHtml + '</ul>';
        $('body').append(targetMenuHtml);
      } else {
        $('.float-sub-menu').html(targetMenuHtml);
      }
      if ((windowHeight - targetTop) > targetHeight) {
        $('.float-sub-menu').css({
          'top': targetTop,
          'left': targetLeft,
          'bottom': 'auto',
          'right': targetRight
        });
      } else {
        $('.float-sub-menu').css({
          'bottom': 0,
          'top': 'auto',
          'left': targetLeft,
          'right': targetRight
        });
      }
    } else {
      $('.float-sub-menu').remove();
      targetFloatMenu = '';
    }
  }, function () {
    floatSubMenuTimeout = setTimeout(function () {
      $('.float-sub-menu').remove();
      targetFloatMenu = '';
    }, 250);
  });
}


/* 07. Handle Dropdown Close Option
 ------------------------------------------------ */
var handleDropdownClose = function () {
  $(document).on('click', '[data-dropdown-close="false"]', function (e) {
    e.stopPropagation();
  });
};


/* Application Controller
 ------------------------------------------------ */
var App = function () {
  "use strict";

  return {
    //main function
    init: function () {
      this.initSidebar();
      this.initHeader();
      this.initComponent();
    },
    initSidebar: function () {
      handleSidebarMinifyFloatMenu();
      handleSidebarMenu();
      handleSidebarMinify();
      handleSidebarScrollMemory();
    },
    initHeader: function () {
      handleHeaderSearchBar();
    },
    initComponent: function () {
      handleSlimScroll();
      handleDropdownClose();
    }
  };
}();
