/*
 Template Name: Infinite Admin - Responsive Admin Dashboard Template build with Twitter Bootstrap 3.3.7 & Bootstrap 4
 Version: 1.3.0
 Author: Sean Ngu
 Website: http://www.seantheme.com/infinite-admin/admin/html/
 ----------------------------
 APPS CONTENT TABLE
 ----------------------------

 <!-- ======== GLOBAL SCRIPT SETTING ======== -->
 01. Global Variable
 02. Handle Scrollbar
 03. Handle Header Search Bar
 04. Handle Sidebar Menu
 05. Handle Sidebar Minify
 06. Handle Sidebar Scroll Memory
 07. Handle Sidebar Minify Float Menu
 08. Handle Dropdown Close Option
 09. Handle App Notification
 10. Handle Theme Panel & Cookie
 11. Handle Panel - Remove / Reload / Collapse / Expand
 12. Handle Tooltip & Popover Activation
 13. Handle Scroll to Top Button Activation
 14. Handle Page Load Fade In

 <!-- ======== APPLICATION SETTING ======== -->
 Application Controller
 */



/* 01. Global Variable
 ------------------------------------------------ */
var MUTED_COLOR = '#8A8A8F';
var MUTED_TRANSPARENT_1_COLOR = 'rgba(138, 138, 143, 0.1)';
var MUTED_TRANSPARENT_2_COLOR = 'rgba(138, 138, 143, 0.2)';
var MUTED_TRANSPARENT_3_COLOR = 'rgba(138, 138, 143, 0.3)';
var MUTED_TRANSPARENT_4_COLOR = 'rgba(138, 138, 143, 0.4)';
var MUTED_TRANSPARENT_5_COLOR = 'rgba(138, 138, 143, 0.5)';
var MUTED_TRANSPARENT_6_COLOR = 'rgba(138, 138, 143, 0.6)';
var MUTED_TRANSPARENT_7_COLOR = 'rgba(138, 138, 143, 0.7)';
var MUTED_TRANSPARENT_8_COLOR = 'rgba(138, 138, 143, 0.8)';
var MUTED_TRANSPARENT_9_COLOR = 'rgba(138, 138, 143, 0.9)';

var PRIMARY_COLOR = '#007AFF';
var PRIMARY_TRANSPARENT_1_COLOR = 'rgba(0, 185, 99, 0.1)';
var PRIMARY_TRANSPARENT_2_COLOR = 'rgba(0, 185, 99, 0.2)';
var PRIMARY_TRANSPARENT_3_COLOR = 'rgba(0, 185, 99, 0.3)';
var PRIMARY_TRANSPARENT_4_COLOR = 'rgba(0, 185, 99, 0.4)';
var PRIMARY_TRANSPARENT_5_COLOR = 'rgba(0, 185, 99, 0.5)';
var PRIMARY_TRANSPARENT_6_COLOR = 'rgba(0, 185, 99, 0.6)';
var PRIMARY_TRANSPARENT_7_COLOR = 'rgba(0, 185, 99, 0.7)';
var PRIMARY_TRANSPARENT_8_COLOR = 'rgba(0, 185, 99, 0.8)';
var PRIMARY_TRANSPARENT_9_COLOR = 'rgba(0, 185, 99, 0.9)';

var SUCCESS_COLOR = '#4CD964';
var SUCCESS_TRANSPARENT_1_COLOR = 'rgba(76, 217, 100, 0.1)';
var SUCCESS_TRANSPARENT_2_COLOR = 'rgba(76, 217, 100, 0.2)';
var SUCCESS_TRANSPARENT_3_COLOR = 'rgba(76, 217, 100, 0.3)';
var SUCCESS_TRANSPARENT_4_COLOR = 'rgba(76, 217, 100, 0.4)';
var SUCCESS_TRANSPARENT_5_COLOR = 'rgba(76, 217, 100, 0.5)';
var SUCCESS_TRANSPARENT_6_COLOR = 'rgba(76, 217, 100, 0.6)';
var SUCCESS_TRANSPARENT_7_COLOR = 'rgba(76, 217, 100, 0.7)';
var SUCCESS_TRANSPARENT_8_COLOR = 'rgba(76, 217, 100, 0.8)';
var SUCCESS_TRANSPARENT_9_COLOR = 'rgba(76, 217, 100, 0.9)';

var INFO_COLOR = '#5AC8FA';
var INFO_TRANSPARENT_1_COLOR = 'rgba(90, 200, 250, 0.1)';
var INFO_TRANSPARENT_2_COLOR = 'rgba(90, 200, 250, 0.2)';
var INFO_TRANSPARENT_3_COLOR = 'rgba(90, 200, 250, 0.3)';
var INFO_TRANSPARENT_4_COLOR = 'rgba(90, 200, 250, 0.4)';
var INFO_TRANSPARENT_5_COLOR = 'rgba(90, 200, 250, 0.5)';
var INFO_TRANSPARENT_6_COLOR = 'rgba(90, 200, 250, 0.6)';
var INFO_TRANSPARENT_7_COLOR = 'rgba(90, 200, 250, 0.7)';
var INFO_TRANSPARENT_8_COLOR = 'rgba(90, 200, 250, 0.8)';
var INFO_TRANSPARENT_9_COLOR = 'rgba(90, 200, 250, 0.9)';

var WARNING_COLOR = '#FF9500';
var WARNING_TRANSPARENT_1_COLOR = 'rgba(255, 149, 0, 0.1)';
var WARNING_TRANSPARENT_2_COLOR = 'rgba(255, 149, 0, 0.2)';
var WARNING_TRANSPARENT_3_COLOR = 'rgba(255, 149, 0, 0.3)';
var WARNING_TRANSPARENT_4_COLOR = 'rgba(255, 149, 0, 0.4)';
var WARNING_TRANSPARENT_5_COLOR = 'rgba(255, 149, 0, 0.5)';
var WARNING_TRANSPARENT_6_COLOR = 'rgba(255, 149, 0, 0.6)';
var WARNING_TRANSPARENT_7_COLOR = 'rgba(255, 149, 0, 0.7)';
var WARNING_TRANSPARENT_8_COLOR = 'rgba(255, 149, 0, 0.8)';
var WARNING_TRANSPARENT_9_COLOR = 'rgba(255, 149, 0, 0.9)';

var DANGER_COLOR = '#FF3B30';
var DANGER_TRANSPARENT_1_COLOR = 'rgba(255, 59, 48, 0.1)';
var DANGER_TRANSPARENT_2_COLOR = 'rgba(255, 59, 48, 0.2)';
var DANGER_TRANSPARENT_3_COLOR = 'rgba(255, 59, 48, 0.3)';
var DANGER_TRANSPARENT_4_COLOR = 'rgba(255, 59, 48, 0.4)';
var DANGER_TRANSPARENT_5_COLOR = 'rgba(255, 59, 48, 0.5)';
var DANGER_TRANSPARENT_6_COLOR = 'rgba(255, 59, 48, 0.6)';
var DANGER_TRANSPARENT_7_COLOR = 'rgba(255, 59, 48, 0.7)';
var DANGER_TRANSPARENT_8_COLOR = 'rgba(255, 59, 48, 0.8)';
var DANGER_TRANSPARENT_9_COLOR = 'rgba(255, 59, 48, 0.9)';

var PINK_COLOR = '#FF2D55';
var PINK_TRANSPARENT_1_COLOR = 'rgba(255, 45, 85, 0.1)';
var PINK_TRANSPARENT_2_COLOR = 'rgba(255, 45, 85, 0.2)';
var PINK_TRANSPARENT_3_COLOR = 'rgba(255, 45, 85, 0.3)';
var PINK_TRANSPARENT_4_COLOR = 'rgba(255, 45, 85, 0.4)';
var PINK_TRANSPARENT_5_COLOR = 'rgba(255, 45, 85, 0.5)';
var PINK_TRANSPARENT_6_COLOR = 'rgba(255, 45, 85, 0.6)';
var PINK_TRANSPARENT_7_COLOR = 'rgba(255, 45, 85, 0.7)';
var PINK_TRANSPARENT_8_COLOR = 'rgba(255, 45, 85, 0.8)';
var PINK_TRANSPARENT_9_COLOR = 'rgba(255, 45, 85, 0.9)';

var PURPLE_COLOR = '#5856D6';
var PURPLE_TRANSPARENT_1_COLOR = 'rgba(88, 86, 214, 0.1)';
var PURPLE_TRANSPARENT_2_COLOR = 'rgba(88, 86, 214, 0.2)';
var PURPLE_TRANSPARENT_3_COLOR = 'rgba(88, 86, 214, 0.3)';
var PURPLE_TRANSPARENT_4_COLOR = 'rgba(88, 86, 214, 0.4)';
var PURPLE_TRANSPARENT_5_COLOR = 'rgba(88, 86, 214, 0.5)';
var PURPLE_TRANSPARENT_6_COLOR = 'rgba(88, 86, 214, 0.6)';
var PURPLE_TRANSPARENT_7_COLOR = 'rgba(88, 86, 214, 0.7)';
var PURPLE_TRANSPARENT_8_COLOR = 'rgba(88, 86, 214, 0.8)';
var PURPLE_TRANSPARENT_9_COLOR = 'rgba(88, 86, 214, 0.9)';

var YELLOW_COLOR = '#FFCC00';
var YELLOW_TRANSPARENT_1_COLOR = 'rgba(255, 204, 0, 0.1)';
var YELLOW_TRANSPARENT_2_COLOR = 'rgba(255, 204, 0, 0.2)';
var YELLOW_TRANSPARENT_3_COLOR = 'rgba(255, 204, 0, 0.3)';
var YELLOW_TRANSPARENT_4_COLOR = 'rgba(255, 204, 0, 0.4)';
var YELLOW_TRANSPARENT_5_COLOR = 'rgba(255, 204, 0, 0.5)';
var YELLOW_TRANSPARENT_6_COLOR = 'rgba(255, 204, 0, 0.6)';
var YELLOW_TRANSPARENT_7_COLOR = 'rgba(255, 204, 0, 0.7)';
var YELLOW_TRANSPARENT_8_COLOR = 'rgba(255, 204, 0, 0.8)';
var YELLOW_TRANSPARENT_9_COLOR = 'rgba(255, 204, 0, 0.9)';

var INVERSE_COLOR = '#000000';
var INVERSE_TRANSPARENT_1_COLOR = 'rgba(0, 0, 0, 0.1)';
var INVERSE_TRANSPARENT_2_COLOR = 'rgba(0, 0, 0, 0.2)';
var INVERSE_TRANSPARENT_3_COLOR = 'rgba(0, 0, 0, 0.3)';
var INVERSE_TRANSPARENT_4_COLOR = 'rgba(0, 0, 0, 0.4)';
var INVERSE_TRANSPARENT_5_COLOR = 'rgba(0, 0, 0, 0.5)';
var INVERSE_TRANSPARENT_6_COLOR = 'rgba(0, 0, 0, 0.6)';
var INVERSE_TRANSPARENT_7_COLOR = 'rgba(0, 0, 0, 0.7)';
var INVERSE_TRANSPARENT_8_COLOR = 'rgba(0, 0, 0, 0.8)';
var INVERSE_TRANSPARENT_9_COLOR = 'rgba(0, 0, 0, 0.9)';

var WHITE_COLOR = '#FFFFFF';
var WHITE_TRANSPARENT_1_COLOR = 'rgba(255, 255, 255, 0.1)';
var WHITE_TRANSPARENT_2_COLOR = 'rgba(255, 255, 255, 0.2)';
var WHITE_TRANSPARENT_3_COLOR = 'rgba(255, 255, 255, 0.3)';
var WHITE_TRANSPARENT_4_COLOR = 'rgba(255, 255, 255, 0.4)';
var WHITE_TRANSPARENT_5_COLOR = 'rgba(255, 255, 255, 0.5)';
var WHITE_TRANSPARENT_6_COLOR = 'rgba(255, 255, 255, 0.6)';
var WHITE_TRANSPARENT_7_COLOR = 'rgba(255, 255, 255, 0.7)';
var WHITE_TRANSPARENT_8_COLOR = 'rgba(255, 255, 255, 0.8)';
var WHITE_TRANSPARENT_9_COLOR = 'rgba(255, 255, 255, 0.9)';


/* 02. Handle Scrollbar
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


/* 03. Handle Header Search Bar
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
    search: function() {
      $('.header-search-bar .right-icon').html('<i class="fa fa-spin fa-circle-o-notch"></i>')
    },
    response: function() {
      $('.header-search-bar .right-icon').html('<i class="ti-close"></i>')
    },
    select: function(event, ui) {
        $('#header-search').val(ui.item.value);
        $('#header-search').closest('form').submit();
      }
  }).on('focus', function () {
    $(this).autocomplete('search');
  });
  $('#header-search').autocomplete('widget').addClass('search-bar-autocomplete animated fadeIn');
};


/* 04. Handle Sidebar Menu
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


/* 05. Handle Sidebar Minify
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


/* 06. Handle Sidebar Scroll Memory
 ------------------------------------------------ */
var handleSidebarScrollMemory = function () {
  if (!(/Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent))) {
    $('.sidebar [data-scrollbar="true"]').slimScroll().bind('slimscrolling', function (e, pos) {
      localStorage.setItem('sidebarScrollPosition', pos + 'px');
    });

    var defaultScroll = localStorage.getItem('sidebarScrollPosition');
    if (defaultScroll) {
      $('.sidebar [data-scrollbar="true"]').slimScroll({scrollTo: defaultScroll});
    }
  }
};


/* 07. Handle Sidebar Minify Float Menu
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


/* 08. Handle Dropdown Close Option
 ------------------------------------------------ */
var handleDropdownClose = function () {
  $(document).on('click', '[data-dropdown-close="false"]', function (e) {
    e.stopPropagation();
  });
};


/* 09. Handle App Notification
 ------------------------------------------------ */
var handleAppNotification = function () {
  $.extend({
    notification: function (data) {
      var title = (data.title) ? data.title : '';
      var content = (data.content) ? data.content : '';
      var icon = (data.icon) ? data.icon : '';
      var iconClass = (data.iconClass) ? data.iconClass : '';
      var img = (data.img) ? data.img : '';
      var imgClass = (data.imgClass) ? data.imgClass : '';
      var closeBtn = (data.closeBtn) ? data.closeBtn : '';
      var closeBtnText = (data.closeBtnText) ? data.closeBtnText : '';
      var btn = (data.btn) ? data.btn : '';
      var btnText = (data.btnText) ? data.btnText : '';
      var btnAttr = (data.btnAttr) ? data.btnAttr : '';
      var btnUrl = (data.btnUrl) ? data.btnUrl : '#';
      var autoclose = (data.autoclose) ? data.autoclose : '';
      var autocloseTime = (data.autocloseTime) ? data.autocloseTime : 5000;
      var customClass = (data.class) ? data.class : '';
      var inverseMode = (data.inverseMode) ? 'page-notification-inverse' : '';

      var titleHtml = (title) ? '<h4 class="notification-title">' + title + '</h4>' : '';
      var contentHtml = (content) ? '<p class="notification-desc">' + content + '</p>' : '';
      var mediaHtml = (icon) ? '<div class="notification-media"><i class="' + icon + ' ' + iconClass + '"></i></div>' : '';
      mediaHtml = (img) ? '<div class="notification-media"><img src="' + img + '" class="' + imgClass + '"></i></div>' : mediaHtml;
      var customBtnHtml = (btn && btnText) ? '<a href="' + btnUrl + '" ' + btnAttr + '>' + btnText + '</a>' : '';
      var closeBtnHtml = (closeBtn && closeBtn == 'disabled') ? '' : '<a href="#" data-dismiss="notification">Close</a>';
      var infoHtml = (!titleHtml && !contentHtml) ? '' : '<div class="notification-info">' + titleHtml + contentHtml + '</div>';
      var btnHtmlClass = (!customBtnHtml && closeBtnHtml || customBtnHtml && !closeBtnHtml) ? 'single-btn' : '';
      var btnHtml = '<div class="notification-btn ' + btnHtmlClass + '">' + customBtnHtml + closeBtnHtml + '</div>';
      var finalHtml = '<div class="page-notification ' + customClass + ' bounceInRight animated ' + inverseMode + '">' + mediaHtml + infoHtml + btnHtml + '</div>';

      if ($('#page-notification-container').length === 0) {
        $('body').append('<div id="page-notification-container" class="page-notification-container"></div>');
      }
      $('#page-notification-container').append(finalHtml);
      if (autoclose) {
        var targetElm = $('#page-notification-container').find('.page-notification').last();
        setTimeout(function () {
          $(targetElm).fadeOut(function () {
            $(this).remove();
          });
        }, autocloseTime);
      }
    }
  });

  $(document).on('click', '[data-toggle="notification"]', function (e) {
    e.preventDefault();
    var data = {
      title: ($(this).attr('data-title')) ? $(this).attr('data-title') : '',
      content: ($(this).attr('data-content')) ? $(this).attr('data-content') : '',
      icon: ($(this).attr('data-icon')) ? $(this).attr('data-icon') : '',
      iconClass: ($(this).attr('data-icon-class')) ? $(this).attr('data-icon-class') : '',
      img: ($(this).attr('data-img')) ? $(this).attr('data-img') : '',
      imgClass: ($(this).attr('data-img-class')) ? $(this).attr('data-img-class') : '',
      btn: ($(this).attr('data-btn')) ? $(this).attr('data-btn') : '',
      btnText: ($(this).attr('data-btn-text')) ? $(this).attr('data-btn-text') : '',
      btnAttr: ($(this).attr('data-btn-attr')) ? $(this).attr('data-btn-attr') : '',
      btnUrl: ($(this).attr('data-btn-url')) ? $(this).attr('data-btn-url') : '',
      autoclose: ($(this).attr('data-autoclose')) ? $(this).attr('data-autoclose') : '',
      autocloseTime: ($(this).attr('data-autoclose-time')) ? $(this).attr('data-autoclose-time') : '',
      customClass: ($(this).attr('data-class')) ? $(this).attr('data-class') : '',
      inverseMode: ($(this).attr('data-inverse-mode')) ? $(this).attr('data-inverse-mode') : '',
    };
    $.notification(data);
  });
  $(document).on('click', '[data-dismiss="notification"]', function (e) {
    e.preventDefault();
    $(this).closest('.page-notification').fadeOut(function () {
      $(this).remove();
    });
  });
};


/* 10. Handle Theme Panel & Cookie
 ------------------------------------------------ */
var handleThemePanelExpand = function () {
  $('[data-click="theme-panel-expand"]').click(function (e) {
    e.preventDefault();

    var targetElm = '.theme-panel';
    var targetClass = 'active';

    if ($(targetElm).hasClass(targetClass)) {
      $(targetElm).removeClass(targetClass);
    } else {
      $(targetElm).addClass(targetClass);
    }
  });
};
var handleThemePanelReset = function () {
  $('[data-click="reset-theme-setting"]').click(function (e) {
    e.preventDefault();
    Cookies.remove('theme');
    window.location.href = document.URL;
  });
};
var handleSetThemeCookie = function (field, value) {
  var cookie = (Cookies.getJSON('theme')) ? Cookies.getJSON('theme') : {};
  cookie[field] = value;
  Cookies.set('theme', cookie);
};
var handelThemePanelColorSelector = function () {
  $('[data-click="theme-selector"]').click(function (e) {
    e.preventDefault();
    var targetFile = $(this).attr('data-theme-file');
    var targetTheme = $(this).attr('data-theme');

    $('#theme').attr('href', targetFile);
    $('[data-click="theme-selector"]').not(this).closest('li').removeClass('active');
    $(this).closest('li').addClass('active');
    handleSetThemeCookie('color', targetTheme);
  });
};
var handleThemePanelCookie = function () {

  // SIDEBAR FIXED
  $('.theme-panel #sidebar_fixed').change(function (e) {
    var cookieValue = ($(this).is(':checked')) ? 'fixed' : '';
    if (cookieValue) {
      $('#page-container').addClass('page-sidebar-fixed');
      if (!$('.theme-panel #header_fixed').is(':checked')) {
        $('.theme-panel #header_fixed').prop('checked', true);
        $('.theme-panel #header_fixed').trigger('change');
      }
    } else {
      $('#page-container').removeClass('page-sidebar-fixed');
    }
    handleSetThemeCookie('sidebarPosition', cookieValue);
  });


  // SIDEBAR LIGHT
  $('.theme-panel #sidebar_light').change(function (e) {
    var cookieValue = ($(this).is(':checked')) ? 'light' : '';
    if (cookieValue) {
      $('#sidebar').removeClass('sidebar-inverse');
    } else {
      $('#sidebar').addClass('sidebar-inverse');
    }
    handleSetThemeCookie('sidebarColor', cookieValue);
  });


  // HEADER FIXED
  $('.theme-panel #header_fixed').change(function (e) {
    var cookieValue = ($(this).is(':checked')) ? 'fixed' : '';
    if (cookieValue) {
      $('#page-container').addClass('page-header-fixed');
    } else {
      $('#page-container').removeClass('page-header-fixed');
      if ($('.theme-panel #sidebar_fixed').is(':checked')) {
        $('.theme-panel #sidebar_fixed').prop('checked', false);
        $('.theme-panel #sidebar_fixed').trigger('change');
      }
    }
    handleSetThemeCookie('headerPosition', cookieValue);
  });


  // HEADER DARK
  $('.theme-panel #header_dark').change(function (e) {
    var cookieValue = ($(this).is(':checked')) ? 'dark' : '';
    if (cookieValue) {
      $('#header').addClass('navbar-inverse').removeClass('navbar-default');
    } else {
      $('#header').addClass('navbar-default').removeClass('navbar-inverse');
    }
    handleSetThemeCookie('headerColor', cookieValue);
  });


  // PAGE LOAD COOKIE
  if (Cookies.getJSON('theme')) {
    cookie = Cookies.getJSON('theme');

    if (cookie.color) {
      $('[data-theme="' + cookie.color + '"]').trigger('click');
    }
    if (cookie.headerColor && cookie.headerColor == 'dark') {
      $('.theme-panel #header_dark').prop('checked', true).trigger('change');
    }
    if (cookie.headerFixed && cookie.headerFixed == 'fixed') {
      $('.theme-panel #header_fixed').prop('checked', true).trigger('change');
    }
    if (cookie.sidebarColor && cookie.sidebarColor == 'light') {
      $('.theme-panel #sidebar_light').prop('checked', true).trigger('change');
    }
    if (cookie.sidebarFixed && cookie.sidebarFixed == 'fixed') {
      $('.theme-panel #sidebar_fixed').prop('checked', true).trigger('change');
    }
  } else {
    $('.theme-panel').addClass('active');
  }
};


/* 11. Handle Panel - Remove / Reload / Collapse / Expand
 ------------------------------------------------ */
var panelActionRunning = false;
var handlePanelAction = function () {
  "use strict";

  if (panelActionRunning) {
    return false;
  }
  panelActionRunning = true;

  // remove
  $(document).on('hover', '[data-toggle=panel-remove]', function (e) {
    if (!$(this).attr('data-init')) {
      $(this).tooltip({
        title: 'Remove',
        placement: 'bottom',
        trigger: 'hover',
        container: 'body'
      });
      $(this).tooltip('show');
      $(this).attr('data-init', true);
    }
  });
  $(document).on('click', '[data-toggle=panel-remove]', function (e) {
    e.preventDefault();
    $(this).tooltip('destroy');
    $(this).closest('.panel').remove();
  });

  // collapse
  $(document).on('hover', '[data-toggle=panel-collapse]', function (e) {
    if (!$(this).attr('data-init')) {
      $(this).tooltip({
        title: 'Collapse / Expand',
        placement: 'bottom',
        trigger: 'hover',
        container: 'body'
      });
      $(this).tooltip('show');
      $(this).attr('data-init', true);
    }
  });
  $(document).on('click', '[data-toggle=panel-collapse]', function (e) {
    e.preventDefault();
    $(this).closest('.panel').find('.panel-body').slideToggle();
  });

  // reload
  $(document).on('hover', '[data-toggle=panel-reload]', function (e) {
    if (!$(this).attr('data-init')) {
      $(this).tooltip({
        title: 'Reload',
        placement: 'bottom',
        trigger: 'hover',
        container: 'body'
      });
      $(this).tooltip('show');
      $(this).attr('data-init', true);
    }
  });
  $(document).on('click', '[data-toggle=panel-reload]', function (e) {
    e.preventDefault();
    var target = $(this).closest('.panel');
    if (!$(target).hasClass('panel-loading')) {
      var targetBody = $(target).find('.panel-body');
      var spinnerHtml = '<div class="panel-loading"><div class="spinner"></div></div>';
      $(target).addClass('panel-loading');
      $(targetBody).prepend(spinnerHtml);
      setTimeout(function () {
        $(target).removeClass('panel-loading');
        $(target).find('.panel-loading').remove();
      }, 2000);
    }
  });

  // expand
  $(document).on('hover', '[data-toggle=panel-expand]', function (e) {
    if (!$(this).attr('data-init')) {
      $(this).tooltip({
        title: 'Expand / Compress',
        placement: 'bottom',
        trigger: 'hover',
        container: 'body'
      });
      $(this).tooltip('show');
      $(this).attr('data-init', true);
    }
  });
  $(document).on('click', '[data-toggle=panel-expand]', function (e) {
    e.preventDefault();
    var target = $(this).closest('.panel');
    var targetBody = $(target).find('.panel-body');
    var targetTop = 40;
    if ($(targetBody).length !== 0) {
      var targetOffsetTop = $(target).offset().top;
      var targetBodyOffsetTop = $(targetBody).offset().top;
      targetTop = targetBodyOffsetTop - targetOffsetTop;
    }

    if ($('body').hasClass('panel-expand') && $(target).hasClass('panel-expand')) {
      $('body, .panel').removeClass('panel-expand');
      $('.panel').removeAttr('style');
      $(targetBody).removeAttr('style');
    } else {
      $('body').addClass('panel-expand');
      $(this).closest('.panel').addClass('panel-expand');

      if ($(targetBody).length !== 0 && targetTop != 40) {
        var finalHeight = 40;
        $(target).find(' > *').each(function () {
          var targetClass = $(this).attr('class');

          if (targetClass != 'panel-heading' && targetClass != 'panel-body') {
            finalHeight += $(this).height() + 30;
          }
        });
        if (finalHeight != 40) {
          $(targetBody).css('top', finalHeight + 'px');
        }
      }
    }
    $(window).trigger('resize');
  });
};


/* 12. Handle Tooltip & Popover Activation
 ------------------------------------------------ */
var handelTooltipPopoverActivation = function () {
  "use strict";
  if ($('[data-toggle="tooltip"]').length !== 0) {
    $('[data-toggle=tooltip]').tooltip();
  }
  if ($('[data-toggle="popover"]').length !== 0) {
    $('[data-toggle=popover]').popover();
  }
};


/* 13. Handle Scroll to Top Button Activation
 ------------------------------------------------ */
var handleScrollToTopButton = function () {
  "use strict";
  $(document).scroll(function () {
    var totalScroll = $(document).scrollTop();

    if (totalScroll >= 200) {
      $('[data-click=scroll-top]').addClass('in');
    } else {
      $('[data-click=scroll-top]').removeClass('in');
    }
  });
  $('.content').scroll(function () {
    var totalScroll = $('.content').scrollTop();

    if (totalScroll >= 200) {
      $('[data-click=scroll-top]').addClass('in');
    } else {
      $('[data-click=scroll-top]').removeClass('in');
    }
  });

  $('[data-click=scroll-top]').click(function (e) {
    e.preventDefault();
    $('html, body, .content').animate({
      scrollTop: $("body").offset().top
    }, 500);
  });
};


/* 14. Handle Page Load Fade In
 ------------------------------------------------ */
var handlePageLoadFadeIn = function () {
  $('#page-container').addClass('in');
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
      this.initThemePanel();
      this.initPage();
    },
    initPage: function () {
//      handlePageLoadFadeIn();
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
      handlePanelAction();
      // handelTooltipPopoverActivation();
      handleScrollToTopButton();
      handleDropdownClose();
      handleAppNotification();
    },
    initThemePanel: function () {
      handleThemePanelExpand();
      handleThemePanelReset();
      handelThemePanelColorSelector();
      handleThemePanelCookie();
    },
    scrollTop: function () {
      $('html, body, .content').animate({
        scrollTop: $('body').offset().top
      }, 0);
    }
  };
}();
